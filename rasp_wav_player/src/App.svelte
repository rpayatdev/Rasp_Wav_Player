<script lang="ts">
  import { onMount, tick } from "svelte";
  import { fade, scale } from "svelte/transition";
  import DirView, { type DirNode } from "./lib/DirView.svelte";

  interface Track {
    name: string;
    fileHandle: FileSystemFileHandle;
    sizeBytes: number;
    ramUrl: string | null;
    preloaded: boolean;
  }

  interface UiErrorItem {
    id: number;
    source: "dir" | "preload" | "play";
    title: string;
    message: string;
    createdAt: number;
  }

  let audioElement: HTMLAudioElement | null = null;
  let isPlaying = false;
  let currentTime = 0;
  let duration = 0;
  let volume = 0.75;
  let lastWsDownTs: number | null = null;
  let lastPlayCallTs: number | null = null;
  let lastPlayTrigger: "gpio" | "ui" | "other" | null = null;
  let lastWsHandledTs = 0;
  let lastWsDownSeq: number | null = null;
  let isPreloadingDir = false;
  let preloadProgressCount = 0;
  let preloadTotalCount = 0;
  let preloadError: string | null = null;
  let preloadRunId = 0;
  let preloadMode: "full" | "rolling" = "full";
  let playError: string | null = null;
  let playAttemptId = 0;
  let playRequestedExplicitly = false;
  let isPlayStarting = false;
  let fallbackDirectUrl: string | null = null;

  // --- GPIO / WebSocket ---
  let ws: WebSocket | null = null;

  type GpioStatus = "disconnected" | "connecting" | "connected" | "error";
  let gpioStatus: GpioStatus = "disconnected";

  const formatTimestamp = (): string => {
    const now = new Date();
    const iso = now.toISOString(); // YYYY-MM-DDTHH:mm:ss.sssZ
    return iso.replace("T", " ").replace("Z", "");
  };

  const wsLog = (
    level: "info" | "warn" | "error",
    message: string,
    ...args: unknown[]
  ): void => {
    const prefix = `[WS ${formatTimestamp()}]`;
    if (level === "error") {
      console.error(prefix, message, ...args);
    } else if (level === "warn") {
      console.warn(prefix, message, ...args);
    } else {
      console.log(prefix, message, ...args);
    }
  };

  function updateGpioStatus(next: GpioStatus): void {
    if (gpioStatus !== next) {
      gpioStatus = next;
    }
  }

  // aktuell sichtbare Playlist (immer nur der gewählte Ordner)
  let tracks: Track[] = [];
  let currentIndex = 0;

  // Directory / FS-Handling
  let rootDirHandle: FileSystemDirectoryHandle | null = null;
  let rootDirName = ""; // Name des Ursprungsordners (für Anzeige + Tooltip)
  let directoryTree: DirNode | null = null; // intern für Flatten
  let directories: DirNode[] = []; // flache Liste aller Ordner (Full-Path relativ zum Root)
  let selectedDirPath: string | null = null;

  let dirError: string | null = null;
  let isLoadingDir = false;
  const ROLLING_CACHE_NOTICE =
    "Low-RAM mode active: caching current + next track only.";
  let uiErrorQueue: UiErrorItem[] = [];
  let nextUiErrorId = 1;
  let lastSeenDirError: string | null = null;
  let lastSeenPreloadError: string | null = null;
  let lastSeenPlayError: string | null = null;
  let errorModalCloseButton: HTMLButtonElement | null = null;
  let lastFocusedErrorId: number | null = null;
  let currentUiError: UiErrorItem | null = null;

  // Scroll-Ref für Playlist
  let playlistScrollContainer: HTMLDivElement | null = null;

  const currentTrack = (): Track | null =>
    tracks.length > 0 ? tracks[currentIndex] : null;

  const nextTrackIndex = (index: number): number =>
    tracks.length === 0 ? 0 : (index + 1) % tracks.length;

  const activeUiError = (): UiErrorItem | null => uiErrorQueue[0] ?? null;

  const showRamLoadingOverlay = (): boolean =>
    tracks.length > 0 && isPreloadingDir;

  function enqueueUiError(
    source: UiErrorItem["source"],
    title: string,
    message: string,
  ): void {
    const item: UiErrorItem = {
      id: nextUiErrorId,
      source,
      title,
      message,
      createdAt: Date.now(),
    };
    nextUiErrorId += 1;
    uiErrorQueue = [...uiErrorQueue, item];
  }

  function dismissActiveUiError(): void {
    if (uiErrorQueue.length === 0) return;
    uiErrorQueue = uiErrorQueue.slice(1);
  }

  function handleWindowKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape") return;
    if (!activeUiError()) return;
    event.preventDefault();
    dismissActiveUiError();
  }

  function isDirectoryReadyForPlayback(): boolean {
    if (tracks.length === 0 || preloadError) return false;
    if (preloadMode === "rolling") {
      return Boolean(currentTrack()?.preloaded && currentTrack()?.ramUrl);
    }
    if (isPreloadingDir) return false;
    return tracks.every((track) => track.preloaded && Boolean(track.ramUrl));
  }

  function currentTrackUrl(): string | undefined {
    return currentTrack()?.ramUrl ?? undefined;
  }

  function clearFallbackDirectUrl(): void {
    if (fallbackDirectUrl) {
      URL.revokeObjectURL(fallbackDirectUrl);
      fallbackDirectUrl = null;
    }
  }

  function clearRamUrlsForTracks(trackList: Track[]): void {
    for (const track of trackList) {
      if (track.ramUrl) {
        URL.revokeObjectURL(track.ramUrl);
      }
      track.ramUrl = null;
      track.preloaded = false;
    }
  }

  function rollingWindowIndices(centerIndex: number): Set<number> {
    const keep = new Set<number>();
    if (tracks.length === 0) return keep;

    const safeCenter = Math.max(0, Math.min(centerIndex, tracks.length - 1));
    keep.add(safeCenter);
    if (tracks.length > 1) {
      keep.add(nextTrackIndex(safeCenter));
    }
    return keep;
  }

  function pruneRamCacheToWindow(keep: Set<number>): void {
    for (let i = 0; i < tracks.length; i += 1) {
      if (keep.has(i)) continue;
      const track = tracks[i];
      if (track.ramUrl) {
        URL.revokeObjectURL(track.ramUrl);
      }
      track.ramUrl = null;
      track.preloaded = false;
    }
  }

  function setRollingProgress(centerIndex: number): void {
    const keep = rollingWindowIndices(centerIndex);
    preloadTotalCount = keep.size;
    preloadProgressCount = Array.from(keep).filter((index) => {
      const track = tracks[index];
      return Boolean(track?.preloaded && track?.ramUrl);
    }).length;
  }

  async function ensureRollingWindowLoaded(
    centerIndex: number,
    runId: number,
  ): Promise<void> {
    if (runId !== preloadRunId || tracks.length === 0) return;
    if (preloadMode !== "rolling") return;
    preloadError = null;

    const keep = rollingWindowIndices(centerIndex);
    const order = Array.from(keep);
    if (order.length === 0) return;

    // Current track first, then preload "next".
    order.sort((a, b) => (a === centerIndex ? -1 : b === centerIndex ? 1 : a - b));

    const current = tracks[centerIndex];
    if (current && (!current.preloaded || !current.ramUrl)) {
      isPreloadingDir = true;
    }

    try {
      for (const index of order) {
        if (runId !== preloadRunId || preloadMode !== "rolling") return;
        const track = tracks[index];
        if (!track || (track.preloaded && track.ramUrl)) continue;

        const file = await track.fileHandle.getFile();
        if (runId !== preloadRunId || preloadMode !== "rolling") return;

        track.ramUrl = URL.createObjectURL(file);
        track.preloaded = true;
      }

      if (runId !== preloadRunId || preloadMode !== "rolling") return;
      pruneRamCacheToWindow(keep);
      setRollingProgress(centerIndex);
      tracks = [...tracks];
    } catch (err) {
      if (runId !== preloadRunId) return;
      preloadError = `Rolling cache failed: ${describePlayError(err)}`;
      wsLog("error", "Rolling cache failed", err);
    } finally {
      if (runId === preloadRunId && preloadMode === "rolling") {
        isPreloadingDir = false;
      }
    }
  }

  function cloneTracksForPlaylist(trackList: Track[]): Track[] {
    return trackList.map((track) => ({
      name: track.name,
      fileHandle: track.fileHandle,
      sizeBytes: track.sizeBytes,
      ramUrl: null,
      preloaded: false,
    }));
  }

  async function preloadDirectoryTracksToRam(
    trackList: Track[],
    runId: number,
  ): Promise<void> {
    preloadMode = "full";
    preloadError = null;
    preloadProgressCount = 0;
    preloadTotalCount = trackList.length;

    if (trackList.length === 0) {
      isPreloadingDir = false;
      return;
    }

    isPreloadingDir = true;

    try {
      for (const track of trackList) {
        if (runId !== preloadRunId) {
          clearRamUrlsForTracks(trackList);
          return;
        }

        const file = await track.fileHandle.getFile();
        track.ramUrl = URL.createObjectURL(file);
        track.preloaded = true;
        preloadProgressCount += 1;

        // Trigger reactivity for progress and per-track readiness.
        tracks = [...tracks];
      }
    } catch (err) {
      if (runId !== preloadRunId) {
        clearRamUrlsForTracks(trackList);
        return;
      }

      clearRamUrlsForTracks(trackList);
      preloadMode = "rolling";
      preloadError = null;
      wsLog("warn", "Full RAM preload failed, switching to rolling cache", err);
      setRollingProgress(currentIndex);
      await ensureRollingWindowLoaded(currentIndex, runId);
    } finally {
      if (runId === preloadRunId && preloadMode === "full") {
        isPreloadingDir = false;
      }
    }
  }

  function formatTime(sec: number): string {
    if (!isFinite(sec)) return "00:00";
    const m = Math.floor(sec / 60);
    const s = Math.floor(sec % 60);
    return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }

  function describePlayError(err: unknown): string {
    if (err instanceof DOMException) {
      return `${err.name}: ${err.message}`;
    }
    if (err instanceof Error) {
      return err.message;
    }
    return String(err);
  }

  function cancelPendingPlayAttempt(): void {
    playAttemptId += 1;
    playRequestedExplicitly = false;
    isPlayStarting = false;
  }

  async function tryPlayWithOptionalFallback(
    source: "ui" | "gpio" | "other",
    startedAt: number,
    attemptId: number,
  ): Promise<void> {
    if (!audioElement || !currentTrack()) return;

    isPlayStarting = true;

    try {
      const playPromise = audioElement.play();
      if (playPromise) {
        await playPromise;
      }
      if (attemptId !== playAttemptId) return;

      isPlayStarting = false;
      playError = null;
      const resolvedAt = performance.now();
      wsLog("info", "Play-Promise erfuellt", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
        dtMs: (resolvedAt - startedAt).toFixed(1),
        sinceWsMs:
          lastWsDownTs !== null ? (resolvedAt - lastWsDownTs).toFixed(1) : undefined,
      });
      return;
    } catch (err) {
      if (attemptId !== playAttemptId) return;
      isPlayStarting = false;

      if (err instanceof DOMException && err.name === "AbortError") {
        playError = null;
        wsLog("info", "Play-Promise abgebrochen (erwartet)", {
          source,
          track: currentTrack()?.name ?? "unbekannt",
        });
        return;
      }

      const initialErrorText = describePlayError(err);
      wsLog("error", "Play-Promise fehlgeschlagen", err);
      wsLog("warn", "Versuche einmaligen Fallback auf direkte File-URL", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
        error: initialErrorText,
      });

      try {
        const track = currentTrack();
        if (!track || !audioElement) {
          playError = `Playback failed: ${initialErrorText}`;
          playRequestedExplicitly = false;
          return;
        }

        clearFallbackDirectUrl();
        const file = await track.fileHandle.getFile();
        if (attemptId !== playAttemptId || !audioElement) return;

        fallbackDirectUrl = URL.createObjectURL(file);
        audioElement.src = fallbackDirectUrl;
        audioElement.load();

        isPlayStarting = true;
        const fallbackPromise = audioElement.play();
        if (fallbackPromise) {
          await fallbackPromise;
        }
        if (attemptId !== playAttemptId) return;

        isPlayStarting = false;
        playError = null;
        wsLog("info", "Fallback-Play erfolgreich", {
          source,
          track: track.name,
        });
      } catch (fallbackErr) {
        if (attemptId !== playAttemptId) return;
        isPlayStarting = false;
        if (
          fallbackErr instanceof DOMException &&
          fallbackErr.name === "AbortError"
        ) {
          playError = null;
          wsLog("info", "Fallback-Play abgebrochen (erwartet)", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
          });
          return;
        }
        const fallbackErrorText = describePlayError(fallbackErr);
        playError = `Playback failed: ${initialErrorText} | fallback failed: ${fallbackErrorText}`;
        playRequestedExplicitly = false;
        wsLog("error", "Fallback-Play fehlgeschlagen", fallbackErr);
      }
    }
  }

  function togglePlay(source: "ui" | "gpio" | "other" = "ui"): void {
    if (!audioElement || !currentTrack()) {
      cancelPendingPlayAttempt();
      wsLog("warn", "Toggle ignoriert: Kein Audioelement/Track", { source });
      return;
    }
    if (!isDirectoryReadyForPlayback() || !currentTrack()?.ramUrl) {
      cancelPendingPlayAttempt();
      wsLog("warn", "Toggle ignoriert: RAM-Preload nicht abgeschlossen", {
        source,
        preloadProgressCount,
        preloadTotalCount,
        preloadError,
      });
      return;
    }

    const now = performance.now();
    lastPlayTrigger = source;
    lastPlayCallTs = now;
    playError = null;

    if (!isPlaying && !isPlayStarting) {
      wsLog("info", "Play angefordert", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
        sinceWsMs:
          source === "gpio" && lastWsDownTs !== null
            ? (now - lastWsDownTs).toFixed(1)
            : undefined,
      });

      playRequestedExplicitly = true;
      playAttemptId += 1;
      const attemptId = playAttemptId;
      void tryPlayWithOptionalFallback(source, now, attemptId);
    } else {
      wsLog("info", isPlayStarting ? "Play-Start abgebrochen" : "Pause angefordert", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
      });
      cancelPendingPlayAttempt();
      if (!audioElement.paused) {
        audioElement.pause();
      }
    }
  }

  function onLoadedMetadata(): void {
    if (!audioElement) return;
    duration = audioElement.duration ?? 0;
    const trackName = currentTrack()?.name ?? "unbekannt";
    wsLog("info", "Metadata geladen", {
      track: trackName,
      durationSec: Number.isFinite(duration) ? duration.toFixed(3) : "n/a",
      readyState: audioElement.readyState,
    });
  }

  function onTimeUpdate(): void {
    if (!audioElement) return;
    currentTime = audioElement.currentTime ?? 0;
  }

  function handlePlay(): void {
    if (!audioElement) return;
    if (!playRequestedExplicitly) {
      isPlayStarting = false;
      wsLog("warn", "Unerwartetes Play ohne expliziten Trigger - stoppe", {
        track: currentTrack()?.name ?? "unbekannt",
      });
      audioElement.pause();
      return;
    }
    playRequestedExplicitly = false;
    isPlayStarting = false;
    const trackName = currentTrack()?.name ?? "unbekannt";
    isPlaying = true;
    playError = null;
    const now = performance.now();
    wsLog("info", "Playback gestartet", {
      track: trackName,
      source: lastPlayTrigger ?? "unbekannt",
      sinceWsMs:
        lastPlayTrigger === "gpio" && lastWsDownTs !== null
          ? (now - lastWsDownTs).toFixed(1)
          : undefined,
      sinceToggleMs:
        lastPlayCallTs !== null ? (now - lastPlayCallTs).toFixed(1) : undefined,
      position: audioElement.currentTime.toFixed(3),
      readyState: audioElement.readyState,
    });
  }

  function handlePause(): void {
    if (!audioElement) return;
    playRequestedExplicitly = false;
    isPlayStarting = false;
    const trackName = currentTrack()?.name ?? "unbekannt";
    isPlaying = false;
    const now = performance.now();
    wsLog("info", "Playback pausiert", {
      track: trackName,
      source: lastPlayTrigger ?? "unbekannt",
      timestampMs: now.toFixed(1),
      position: audioElement.currentTime.toFixed(3),
    });
  }

  function onVolumeChange(): void {
    if (!audioElement) return;
    audioElement.volume = volume;
  }

  function onSeekChange(event: Event): void {
    if (!audioElement || !duration || !isDirectoryReadyForPlayback()) return;
    const target = event.target as HTMLInputElement;
    const value = Number(target.value);
    audioElement.currentTime = (value / 100) * duration;
  }

  async function pickRootDirectory(): Promise<void> {
    dirError = null;

    if (!("showDirectoryPicker" in window)) {
      dirError =
        "Dein Browser unterstützt die File System Access API nicht. Bitte aktuellen Chrome oder Edge verwenden.";
      return;
    }

    try {
      // @ts-ignore
      rootDirHandle = await window.showDirectoryPicker();
      rootDirName = rootDirHandle?.name ?? "";

      isLoadingDir = true;
      preloadRunId += 1;
      cancelPendingPlayAttempt();
      clearRamUrlsForTracks(tracks);
      clearFallbackDirectUrl();

      // Reset State
      tracks = [];
      directoryTree = null;
      directories = [];
      selectedDirPath = null;
      currentIndex = 0;
      currentTime = 0;
      duration = 0;
      isPlaying = false;
      preloadError = null;
      playError = null;
      preloadMode = "full";
      preloadProgressCount = 0;
      preloadTotalCount = 0;
      isPreloadingDir = false;

      if (rootDirHandle) {
        // basePath = "" => alle weiteren Pfade relativ zu diesem Root
        directoryTree = await buildDirectoryTree(rootDirHandle, "");

        if (directoryTree) {
          directories = flattenDirectories(directoryTree);

          // initial: immer Root (path === "") wählen, falls vorhanden
          if (directories.length > 0) {
            selectDirectory(directories[0].path);
          }
        }
      }
    } catch (err: unknown) {
      if (err instanceof DOMException && err.name === "AbortError") return;
      dirError = "Fehler beim Lesen des Verzeichnisses.";
      console.error(err);
    } finally {
      isLoadingDir = false;
    }
  }

  // Dir-Baum rekursiv aufbauen, Pfade RELATIV zum Root
  async function buildDirectoryTree(
    dirHandle: FileSystemDirectoryHandle,
    basePath: string, // "" für Root, "sub", "sub/inner", ...
  ): Promise<DirNode> {
    const dirName =
      basePath === ""
        ? dirHandle.name
        : (basePath.split("/").pop() ?? dirHandle.name);

    const node: DirNode = {
      name: dirName,
      // Pfad ist immer relativ zum Root, Root selbst = ""
      path: basePath,
      children: [],
      wavCount: 0,
      tracks: [],
    };

    for await (const [name, handle] of dirHandle.entries()) {
      const relativePath = basePath ? `${basePath}/${name}` : name;

      if (handle.kind === "directory") {
        const childNode = await buildDirectoryTree(
          handle as FileSystemDirectoryHandle,
          relativePath,
        );
        node.children.push(childNode);
        node.wavCount += childNode.wavCount;
      } else if (handle.kind === "file") {
        if (name.toLowerCase().endsWith(".wav")) {
          const fileHandle = handle as FileSystemFileHandle;
          const file = await fileHandle.getFile();

          const track: Track = {
            // Track-Name = relativer Pfad ab Root (inkl. Unterordner)
            name: relativePath,
            fileHandle,
            sizeBytes: file.size,
            ramUrl: null,
            preloaded: false,
          };

          node.tracks?.push(track);
          node.wavCount += 1;
        }
      }
    }

    node.tracks?.sort(compareTracksNatural);

    return node;
  }

  // Baum -> flache Liste aller Ordner (mit relativen Pfaden)
  function flattenDirectories(root: DirNode): DirNode[] {
    const result: DirNode[] = [];

    function walk(node: DirNode) {
      result.push(node);
      for (const child of node.children) {
        walk(child);
      }
    }

    walk(root);
    return result;
  }

  // Scroll-Helfer für Playlist
  async function scrollPlaylistToTop() {
    await tick();
    if (playlistScrollContainer) {
      playlistScrollContainer.scrollTop = 0;
    }
  }

  async function scrollPlaylistToBottom() {
    await tick();
    if (playlistScrollContainer) {
      playlistScrollContainer.scrollTop = playlistScrollContainer.scrollHeight;
    }
  }

  async function scrollCurrentTrackIntoView() {
    await tick();
    if (!playlistScrollContainer || tracks.length === 0) return;

    const el = document.getElementById(`track-${currentIndex}`);
    if (el) {
      el.scrollIntoView({
        block: "nearest",
        behavior: "smooth",
      });
    }
  }

  // Dateiname ohne Ordner für Playlist-Anzeige
  function getTrackDisplayName(track: Track): string {
    const parts = track.name.split("/");
    return parts[parts.length - 1] || track.name;
  }

  // Tooltip mit vollem Pfad inkl. Ursprungsfolder
  function getTrackTooltip(track: Track): string {
    if (rootDirName) {
      return `${rootDirName}/${track.name}`;
    }
    return track.name;
  }

  // Nummerische Sortierung vor alphabetischer, mit natürlicher Zahlenerkennung
  function tokenizeNatural(name: string): Array<string | number> {
    return name
      .split(/(\d+)/)
      .filter(Boolean)
      .map((part) => (/^\d+$/.test(part) ? Number(part) : part.toLowerCase()));
  }

  function compareTracksNatural(a: Track, b: Track): number {
    const nameA = getTrackDisplayName(a);
    const nameB = getTrackDisplayName(b);

    const startsWithDigitA = /^\d/.test(nameA);
    const startsWithDigitB = /^\d/.test(nameB);

    if (startsWithDigitA !== startsWithDigitB) {
      return startsWithDigitA ? -1 : 1;
    }

    const partsA = tokenizeNatural(nameA);
    const partsB = tokenizeNatural(nameB);
    const len = Math.max(partsA.length, partsB.length);

    for (let i = 0; i < len; i += 1) {
      const partA = partsA[i];
      const partB = partsB[i];

      if (partA === undefined) return -1;
      if (partB === undefined) return 1;

      if (typeof partA === "number" && typeof partB === "number") {
        if (partA !== partB) return partA - partB;
      } else if (typeof partA === "number") {
        return -1;
      } else if (typeof partB === "number") {
        return 1;
      } else if (partA !== partB) {
        return partA.localeCompare(partB, undefined, { sensitivity: "base" });
      }
    }

    return 0;
  }

  // Ordner auswählen: Playlist = WAVs aus diesem Ordner (nicht rekursiv)
  function selectDirectory(path: string): void {
    if (!directoryTree || directories.length === 0) return;

    const dir = directories.find((d) => d.path === path);
    if (!dir) return;

    preloadRunId += 1;
    cancelPendingPlayAttempt();
    const runId = preloadRunId;
    playError = null;
    clearRamUrlsForTracks(tracks);
    clearFallbackDirectUrl();

    selectedDirPath = dir.path;

    // Playlist = WAVs nur aus diesem Ordner
    tracks = cloneTracksForPlaylist(dir.tracks ?? []);
    preloadMode = "full";
    currentIndex = 0;
    currentTime = 0;
    duration = 0;
    preloadError = null;
    preloadProgressCount = 0;
    preloadTotalCount = tracks.length;

    // Playlist-Scroll nach oben, wenn Ordner gewechselt wird
    void scrollPlaylistToTop();

    if (audioElement) {
      audioElement.pause();
      isPlaying = false;
      audioElement.removeAttribute("src");
      audioElement.load();
      audioElement.volume = volume;
    }

    void preloadDirectoryTracksToRam(tracks, runId);
  }

  function selectTrack(index: number): void {
    if (tracks.length === 0) return;

    wsLog("info", "Track gewählt", {
      track: tracks[index]?.name ?? `Index ${index}`,
    });

    if (!audioElement) {
      currentIndex = index;
      isPlaying = false;
      currentTime = 0;
      duration = 0;
      if (preloadMode === "rolling") {
        setRollingProgress(currentIndex);
        void ensureRollingWindowLoaded(currentIndex, preloadRunId);
      }
      return;
    }

    // Immer stoppen - kein automatisches Weiterspielen
    audioElement.pause();
    isPlaying = false;
    cancelPendingPlayAttempt();
    playError = null;
    clearFallbackDirectUrl();

    currentIndex = index;
    currentTime = 0;
    duration = 0;

    // Neuen Track laden, aber NICHT autoplayen
    if (audioElement && currentTrack()) {
      audioElement.volume = volume;
      audioElement.load();
    }
    if (preloadMode === "rolling") {
      setRollingProgress(currentIndex);
      void ensureRollingWindowLoaded(currentIndex, preloadRunId);
    }
  }

  // Navigation: zurück (Wrap-Around)
  function goPrevTrack(): void {
    if (tracks.length === 0) return;
    const prevIndex = currentIndex === 0 ? tracks.length - 1 : currentIndex - 1;
    const wasAtStart = currentIndex === 0;

    selectTrack(prevIndex);

    // Wenn wir von 0 nach ganz unten springen, die Liste komplett nach unten scrollen
    if (wasAtStart && prevIndex === tracks.length - 1) {
      void scrollPlaylistToBottom();
    }
  }

  // Navigation: vorwärts mit Wrap-Around
  function goNextTrack(): void {
    if (tracks.length === 0) return;
    const wasAtEnd = currentIndex === tracks.length - 1;
    const nextIndex = (currentIndex + 1) % tracks.length;

    selectTrack(nextIndex);

    // Wenn wir von Ende auf 0 springen, Liste komplett nach oben scrollen
    if (wasAtEnd && nextIndex === 0) {
      void scrollPlaylistToTop();
    }
  }

  function onEnded(): void {
    playRequestedExplicitly = false;
    isPlayStarting = false;
    const trackName = currentTrack()?.name ?? "unbekannt";
    const position =
      audioElement && Number.isFinite(audioElement.currentTime)
        ? audioElement.currentTime.toFixed(3)
        : "n/a";
    wsLog("info", "Track zu Ende", { track: trackName, position });
    if (tracks.length === 0) {
      isPlaying = false;
      currentTime = 0;
      return;
    }

    // wie Next-Button behandeln (inkl. Wrap-Scroll-Logik)
    goNextTrack();
  }

  function closeApp(): void {
    // 1. Versuche den Backend-Dienst zu informieren (GPIO-Server)
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send("EXIT");
    }

    // 2. Versuche, das Fenster zu schlieÃŸen (Chromium im Kiosk-/App-Modus)
    try {
      window.close();
    } catch (e) {
      console.warn("window.close() wurde blockiert:", e);
    }
  }

  const handleGpioMessage = (event: MessageEvent): void => {
    const msg =
      typeof event.data === "string" ? event.data.trim() : String(event.data);

    let downSeq: number | null = null;
    if (msg === "DOWN") {
      downSeq = null;
    } else if (msg.startsWith("DOWN:")) {
      const rawSeq = msg.slice("DOWN:".length).trim();
      const parsedSeq = Number(rawSeq);
      if (!Number.isInteger(parsedSeq) || parsedSeq <= 0) {
        wsLog("warn", "DOWN mit ungÃ¼ltiger Sequenz ignoriert", { rawSeq, msg });
        return;
      }
      downSeq = parsedSeq;
    } else {
      return;
    }

    const receivedAt = performance.now();
    lastWsDownTs = receivedAt;
    wsLog("info", `Nachricht empfangen: ${msg}`, {
      receivedMs: receivedAt.toFixed(1),
      seq: downSeq ?? undefined,
    });

    const nowTs = performance.now();
    if (downSeq !== null && downSeq === lastWsDownSeq) {
      wsLog("warn", "DOWN mit doppelter Sequenz ignoriert", { seq: downSeq });
      return;
    }

    // Legacy plain DOWN keeps the existing 100ms anti-double-trigger throttle.
    if (downSeq === null && nowTs - lastWsHandledTs < 100) {
      wsLog("warn", "DOWN gedrosselt (zu schnell hintereinander)", {
        deltaMs: (nowTs - lastWsHandledTs).toFixed(1),
      });
      return;
    }

    if (downSeq !== null) {
      lastWsDownSeq = downSeq;
    }
    lastWsHandledTs = nowTs;

    if (!audioElement) {
      wsLog("warn", "DOWN ignoriert: Audioelement noch nicht bereit");
      return;
    }

    if (tracks.length === 0) {
      wsLog("warn", "DOWN ignoriert: Keine Tracks geladen");
      return;
    }
    if (!isDirectoryReadyForPlayback() || !currentTrack()?.ramUrl) {
      wsLog("warn", "DOWN ignoriert: RAM-Preload noch nicht fertig", {
        preloadProgressCount,
        preloadTotalCount,
        preloadError,
      });
      return;
    }

    const trackName = currentTrack()?.name ?? "unbekannt";
    const wasPaused = audioElement.paused;

    if (!wasPaused) {
      lastPlayTrigger = "gpio";
      lastPlayCallTs = receivedAt;
      cancelPendingPlayAttempt();
      wsLog("info", "GPIO Pause angefordert", {
        track: trackName,
        position: Number.isFinite(audioElement.currentTime)
          ? audioElement.currentTime.toFixed(3)
          : "n/a",
      });
      audioElement.pause();
      return;
    }

    wsLog("info", "GPIO Play angefordert (RAM bereit)", { track: trackName });
    togglePlay("gpio");
  };

// --- Titel / Marquee-Logik ---

  let titleElement: HTMLElement | null = null;
  let titleState: "normal" | "small" | "marquee" = "normal";

  function isOverflowing(el: HTMLElement): boolean {
    return el.scrollWidth > el.clientWidth + 1;
  }

  async function recalcTitleState() {
    if (!titleElement) return;

    // 1. Normal
    titleState = "normal";
    await tick();
    if (!titleElement || !isOverflowing(titleElement)) return;

    // 2. Klein
    titleState = "small";
    await tick();
    if (!titleElement || !isOverflowing(titleElement)) return;

    // 3. Marquee
    titleState = "marquee";
  }

  // Recalc, wenn Tracks oder Index sich ändern
  $: if (titleElement) {
    tracks;
    currentIndex;
    void recalcTitleState();
  }

  // Aktueller Track soll im sichtbaren Playlist-Bereich bleiben
  $: if (tracks.length > 0) {
    currentIndex;
    void scrollCurrentTrackIntoView();
  }

  $: if (dirError === null) {
    lastSeenDirError = null;
  } else if (dirError !== lastSeenDirError) {
    enqueueUiError("dir", "Ordnerfehler", dirError);
    lastSeenDirError = dirError;
  }

  $: if (preloadError === null) {
    lastSeenPreloadError = null;
  } else if (preloadError !== lastSeenPreloadError) {
    enqueueUiError("preload", "RAM-Preload-Fehler", preloadError);
    lastSeenPreloadError = preloadError;
  }

  $: if (playError === null) {
    lastSeenPlayError = null;
  } else if (playError !== lastSeenPlayError) {
    enqueueUiError("play", "Wiedergabe-Fehler", playError);
    lastSeenPlayError = playError;
  }

  $: currentUiError = activeUiError();

  $: {
    if (!currentUiError) {
      lastFocusedErrorId = null;
    } else if (currentUiError.id !== lastFocusedErrorId) {
      lastFocusedErrorId = currentUiError.id;
      void tick().then(() => {
        errorModalCloseButton?.focus();
      });
    }
  }

  onMount(() => {
    // Audio initial setzen
    if (audioElement) {
      audioElement.volume = volume;
    }

    const handleResize = () => {
      if (titleElement) {
        void recalcTitleState();
      }
    };

    window.addEventListener("resize", handleResize);
    if (titleElement) {
      void recalcTitleState();
    }

    // --- GPIO / WebSocket: Verbindung aufbauen ---
    updateGpioStatus("connecting");

    const wsPort = 8080;
    const wsProtocol = window.location.protocol === "https:" ? "wss" : "ws";

    const wsUrl = `${wsProtocol}://${window.location.hostname}:${wsPort}`;

    wsLog("info", `Verbinde zu ${wsUrl}`);
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
      updateGpioStatus("connected");
      wsLog("info", "WebSocket verbunden");
    };

    ws.onmessage = handleGpioMessage;

    ws.onerror = (err) => {
      wsLog("error", "WebSocket Fehler", err);
      updateGpioStatus("error");
    };

    ws.onclose = (event) => {
      wsLog("warn", "WebSocket getrennt", {
        code: event.code,
        reason: event.reason,
        wasClean: event.wasClean,
      });
      updateGpioStatus("disconnected");
    };

    return () => {
      preloadRunId += 1;
      cancelPendingPlayAttempt();
      clearRamUrlsForTracks(tracks);
      clearFallbackDirectUrl();
      window.removeEventListener("resize", handleResize);
      ws?.close();
    };
  });
</script>

<svelte:window on:keydown={handleWindowKeydown} />

<main>
  <div class="app-topbar">
    <button
      class="close-button"
      type="button"
      on:click={closeApp}
      aria-label="Anwendung schließen"
    >
      ✕
    </button>
  </div>
  <div class="player-layout">
    <!-- 1. Player -->
    <article class="player-card">
      <header class="player-card-header">
        <h2 class="player-title">
          <span class="player-title-icon">🎵</span>
          <span
            class="player-title-text-wrapper
              {titleState === 'small' ? 'player-title--small' : ''}
              {titleState === 'marquee' ? 'player-title--marquee' : ''}"
            bind:this={titleElement}
          >
            <span class="player-title-text">
              {#if tracks.length > 0}
                {getTrackDisplayName(tracks[currentIndex])}
              {:else}
                Kein Track gewählt
              {/if}
            </span>
          </span>
        </h2>
      </header>

      <audio
        bind:this={audioElement}
        src={currentTrackUrl()}
        preload="auto"
        on:loadedmetadata={onLoadedMetadata}
        on:timeupdate={onTimeUpdate}
        on:play={handlePlay}
        on:pause={handlePause}
        on:ended={onEnded}
      ></audio>

      <div class="control-buttons">
        <button
          on:click={goPrevTrack}
          disabled={tracks.length === 0}
        >
          ⏮
        </button>

        <button
          on:click={() => togglePlay("ui")}
          disabled={tracks.length === 0 || !isDirectoryReadyForPlayback()}
        >
          {isPlaying ? "⏸" : "▶"}
        </button>

        <button
          on:click={goNextTrack}
          disabled={tracks.length === 0}
        >
          ⏭
        </button>
      </div>

      <input
        type="range"
        min="0"
        max="100"
        step="0.1"
        value={duration ? (currentTime / duration) * 100 : 0}
        on:input={onSeekChange}
        disabled={tracks.length === 0 || !isDirectoryReadyForPlayback()}
      />

      <div class="time">
        <span>{formatTime(currentTime)}</span>
        <span>{formatTime(duration)}</span>
      </div>

      <div class="volume-area">
        <label for="volume">Volume</label>
        <input
          id="volume"
          type="range"
          min="0"
          max="1"
          step="0.01"
          bind:value={volume}
          on:input={onVolumeChange}
        />
      </div>

      {#if tracks.length > 0}
        <p class="gpio-status">
          {#if preloadMode === "rolling"}
            {ROLLING_CACHE_NOTICE} ({preloadProgressCount}/{preloadTotalCount})
          {:else if isPreloadingDir}
            Loading into RAM: {preloadProgressCount}/{preloadTotalCount}
          {:else if isDirectoryReadyForPlayback()}
            RAM preload complete: {preloadTotalCount}/{preloadTotalCount}
          {:else}
            RAM preload pending
          {/if}
        </p>
      {/if}

            <p class="gpio-status">
        GPIO-Button:&nbsp;
        {#if gpioStatus === "connected"}
          🟢 verbunden
        {:else if gpioStatus === "connecting"}
          🟡 verbinden…
        {:else if gpioStatus === "error"}
          🔴 Fehler
        {:else}
          ⚪ nicht verbunden
        {/if}
      </p>
    </article>

    <!-- 2. Ordner -->
    <article class="player-card">
      <header class="player-card-header">
        <h2>Ordner</h2>
        <button
          class="icon-button"
          on:click={pickRootDirectory}
          disabled={isLoadingDir}
          aria-label="Root-Verzeichnis wählen"
        >
          📂
        </button>
      </header>

      {#if directories.length > 0}
        <div class="dir-list-container">
          <DirView
            {directories}
            {selectedDirPath}
            {rootDirName}
            on:select={(event) => selectDirectory(event.detail)}
          />
        </div>
      {:else}
        <p class="no-folder-text">Noch kein Ordner gewählt.</p>
      {/if}
    </article>

    <!-- 3. Playlist -->
    <article class="player-card">
      <header class="player-card-header">
        <h2>Playlist</h2>
      </header>

      <section class="playlist">
        {#if tracks.length === 0}
          <p class="playlist-empty">
            Keine .wav-Dateien im gewählten Ordner gefunden.
          </p>
        {:else}
          <div class="playlist-list" bind:this={playlistScrollContainer}>
            {#each tracks as track, i}
              <div class="playlist-item">
                <button
                  id={"track-" + i}
                  type="button"
                  class="playlist-entry {i === currentIndex
                    ? 'playlist-entry--active'
                    : ''}"
                  on:click={() => selectTrack(i)}
                  aria-current={i === currentIndex ? "true" : "false"}
                  title={getTrackTooltip(track)}
                >
                  <span class="playlist-entry-icon">🎵</span>
                  <span class="playlist-entry-name">
                    {getTrackDisplayName(track)}
                  </span>
                </button>
              </div>
            {/each}
          </div>
        {/if}
      </section>
    </article>
  </div>

  {#if showRamLoadingOverlay()}
    <div
      class="ui-overlay-backdrop"
      in:fade={{ duration: 140 }}
      out:fade={{ duration: 120 }}
    >
      <section
        class="ui-loading-popup"
        role="status"
        aria-live="polite"
        in:scale={{ duration: 170, start: 0.96 }}
        out:scale={{ duration: 120, start: 0.98 }}
      >
        <span class="ui-spinner" aria-hidden="true"></span>
        <h3>Lade Songs in den Arbeitsspeicher...</h3>
        <p>{preloadProgressCount}/{preloadTotalCount}</p>
      </section>
    </div>
  {/if}

  {#if currentUiError}
    <div
      class="ui-overlay-backdrop"
      in:fade={{ duration: 160 }}
      out:fade={{ duration: 120 }}
    >
      <div
        class="ui-error-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"ui-error-title-" + currentUiError.id}
        aria-describedby={"ui-error-description-" + currentUiError.id}
        in:scale={{ duration: 180, start: 0.95 }}
        out:scale={{ duration: 130, start: 0.98 }}
      >
        <h3 id={"ui-error-title-" + currentUiError.id}>{currentUiError.title}</h3>
        <p id={"ui-error-description-" + currentUiError.id}>
          {currentUiError.message}
        </p>
        {#if uiErrorQueue.length > 1}
          <p>Noch {uiErrorQueue.length - 1} weitere Meldungen.</p>
        {/if}
        <div class="ui-error-actions">
          <button
            type="button"
            bind:this={errorModalCloseButton}
            on:click={dismissActiveUiError}
          >
            Schliessen
          </button>
        </div>
      </div>
    </div>
  {/if}
</main>
