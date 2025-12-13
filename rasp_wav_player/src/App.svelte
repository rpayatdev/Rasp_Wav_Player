<script lang="ts">
  import { onMount, tick } from "svelte";
  import DirView, { type DirNode } from "./lib/DirView.svelte";

  interface Track {
    name: string;
    url: string;
  }

  let audioElement: HTMLAudioElement | null = null;
  let isPlaying = false;
  let currentTime = 0;
  let duration = 0;
  let volume = 0.75;
  let primePromise: Promise<number | null> | null = null;
  let isPriming = false;
  let lastWsDownTs: number | null = null;
  let lastPlayCallTs: number | null = null;
  let lastPlayTrigger: "gpio" | "ui" | "other" | null = null;

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

  // aktuell sichtbare Playlist (immer nur der gewÃ¤hlte Ordner)
  let tracks: Track[] = [];
  let currentIndex = 0;

  // Directory / FS-Handling
  let rootDirHandle: FileSystemDirectoryHandle | null = null;
  let rootDirName = ""; // Name des Ursprungsordners (fÃ¼r Anzeige + Tooltip)
  let directoryTree: DirNode | null = null; // intern fÃ¼r Flatten
  let directories: DirNode[] = []; // flache Liste aller Ordner (Full-Path relativ zum Root)
  let selectedDirPath: string | null = null;

  let dirError: string | null = null;
  let isLoadingDir = false;

  let objectUrls: string[] = [];

  // Scroll-Ref fÃ¼r Playlist
  let playlistScrollContainer: HTMLDivElement | null = null;

  const currentTrack = (): Track | null =>
    tracks.length > 0 ? tracks[currentIndex] : null;

  function formatTime(sec: number): string {
    if (!isFinite(sec)) return "00:00";
    const m = Math.floor(sec / 60);
    const s = Math.floor(sec % 60);
    return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }

  function togglePlay(source: "ui" | "gpio" | "other" = "ui"): void {
    if (!audioElement || !currentTrack()) {
      wsLog("warn", "Toggle ignoriert: Kein Audioelement/Track", { source });
      return;
    }

    const now = performance.now();
    lastPlayTrigger = source;
    lastPlayCallTs = now;

    if (audioElement.paused) {
      wsLog("info", "Play angefordert", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
        sinceWsMs:
          source === "gpio" && lastWsDownTs !== null
            ? (now - lastWsDownTs).toFixed(1)
            : undefined,
      });

      const playPromise = audioElement.play();
      if (playPromise) {
        playPromise
          .then(() => {
            const resolvedAt = performance.now();
            wsLog("info", "Play-Promise erfÃ¼llt", {
              source,
              track: currentTrack()?.name ?? "unbekannt",
              dtMs: (resolvedAt - now).toFixed(1),
              sinceWsMs:
                lastWsDownTs !== null
                  ? (resolvedAt - lastWsDownTs).toFixed(1)
                  : undefined,
            });
          })
          .catch((err) => {
            wsLog("error", "Play-Promise fehlgeschlagen", err);
          });
      }
    } else {
      wsLog("info", "Pause angefordert", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
      });
      audioElement.pause();
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
    const trackName = currentTrack()?.name ?? "unbekannt";
    if (isPriming) {
      wsLog("info", "Playback-Event während Prime (stumm)", {
        track: trackName,
      });
      return;
    }
    isPlaying = true;
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
    const trackName = currentTrack()?.name ?? "unbekannt";
    if (isPriming) {
      wsLog("info", "Pause-Event während Prime (stumm)", {
        track: trackName,
      });
      return;
    }
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
    if (!audioElement || !duration) return;
    const target = event.target as HTMLInputElement;
    const value = Number(target.value);
    audioElement.currentTime = (value / 100) * duration;
  }

  function clearObjectUrls(): void {
    for (const url of objectUrls) {
      URL.revokeObjectURL(url);
    }
    objectUrls = [];
  }

  async function primeCurrentTrack(): Promise<number | null> {
    if (!audioElement || tracks.length === 0) {
      wsLog("warn", "Prime Ã¼bersprungen: Kein Audioelement/keine Tracks");
      return null;
    }

    if (primePromise) return primePromise;

    // Nicht wÃ¤hrend laufender Wiedergabe primen, sonst droppen wir kurz den Ton.
    if (!audioElement.paused) {
      wsLog("info", "Prime Ã¼bersprungen: Bereits in Wiedergabe");
      return null;
    }

    primePromise = (async () => {
      const trackName = currentTrack()?.name ?? "unbekannt";
      const start = performance.now();
      let end: number | null = null;
      wsLog("info", "Prime gestartet", { track: trackName, startMs: start.toFixed(1) });

      try {
        isPriming = true;
        const previousVolume = audioElement.volume;
        const previousMuted = audioElement.muted;
        const previousTime = audioElement.currentTime;

        audioElement.preload = "auto";
        audioElement.load();

        // Kurz anspielen zum Decoden, danach wieder stoppen.
        audioElement.muted = true;
        audioElement.volume = 0;

        const playPromise = audioElement.play();
        if (playPromise) {
          await playPromise;
        }
        audioElement.pause();
        audioElement.currentTime = previousTime;

        audioElement.muted = previousMuted;
        audioElement.volume = previousVolume;
      } catch (err) {
        wsLog("warn", "Audio-Vorbereitung blockiert/fehlgeschlagen", err);
      } finally {
        end = performance.now();
        isPriming = false;
        wsLog("info", "Prime beendet", {
          track: trackName,
          durationMs: (end - start).toFixed(1),
        });
        primePromise = null;
        // Events setzen isPlaying beim Play/Pause ohnehin neu.
      }

      return end ?? performance.now();
    })();

    return primePromise;
  }

  async function pickRootDirectory(): Promise<void> {
    dirError = null;

    if (!("showDirectoryPicker" in window)) {
      dirError =
        "Dein Browser unterstÃ¼tzt die File System Access API nicht. Bitte aktuellen Chrome oder Edge verwenden.";
      return;
    }

    try {
      // @ts-ignore
      rootDirHandle = await window.showDirectoryPicker();
      rootDirName = rootDirHandle?.name ?? "";

      isLoadingDir = true;
      clearObjectUrls();

      // Reset State
      tracks = [];
      directoryTree = null;
      directories = [];
      selectedDirPath = null;
      currentIndex = 0;
      currentTime = 0;
      duration = 0;
      isPlaying = false;

      if (rootDirHandle) {
        // basePath = "" => alle weiteren Pfade relativ zu diesem Root
        directoryTree = await buildDirectoryTree(rootDirHandle, "");

        if (directoryTree) {
          directories = flattenDirectories(directoryTree);

          // initial: immer Root (path === "") wÃ¤hlen, falls vorhanden
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
    basePath: string, // "" fÃ¼r Root, "sub", "sub/inner", ...
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
          const url = URL.createObjectURL(file);
          objectUrls.push(url);

          const track: Track = {
            // Track-Name = relativer Pfad ab Root (inkl. Unterordner)
            name: relativePath,
            url,
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

  // Scroll-Helfer fÃ¼r Playlist
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

  // Dateiname ohne Ordner fÃ¼r Playlist-Anzeige
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

  // Nummerische Sortierung vor alphabetischer, mit natÃ¼rlicher Zahlenerkennung
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

  // Ordner auswÃ¤hlen: Playlist = WAVs aus diesem Ordner (nicht rekursiv)
  function selectDirectory(path: string): void {
    if (!directoryTree || directories.length === 0) return;

    const dir = directories.find((d) => d.path === path);
    if (!dir) return;

    selectedDirPath = dir.path;

    // Playlist = WAVs nur aus diesem Ordner
    tracks = dir.tracks ?? [];
    currentIndex = 0;
    currentTime = 0;
    duration = 0;

    // Playlist-Scroll nach oben, wenn Ordner gewechselt wird
    void scrollPlaylistToTop();

    if (!audioElement) return;

    audioElement.pause();
    isPlaying = false;

    setTimeout(() => {
      if (!audioElement || tracks.length === 0) return;
      audioElement.volume = volume;
      void primeCurrentTrack();
    }, 0);
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
      return;
    }

    // Immer stoppen â€“ kein automatisches Weiterspielen
    audioElement.pause();
    isPlaying = false;

    currentIndex = index;
    currentTime = 0;
    duration = 0;

    // Neuen Track laden, aber NICHT autoplayen
    setTimeout(() => {
      if (!audioElement || !currentTrack()) return;
      audioElement.volume = volume;
      void primeCurrentTrack();
    }, 0);
  }

  // Navigation: zurÃ¼ck (Wrap-Around)
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

  // Navigation: vorwÃ¤rts mit Wrap-Around
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

  const handleGpioMessage = async (event: MessageEvent): Promise<void> => {
    const msg =
      typeof event.data === "string" ? event.data.trim() : String(event.data);

    const receivedAt = performance.now();
    lastWsDownTs = receivedAt;
    wsLog("info", `Nachricht empfangen: ${msg}`, {
      receivedMs: receivedAt.toFixed(1),
    });

    if (msg !== "DOWN") return;

    if (!audioElement) {
      wsLog("warn", "DOWN ignoriert: Audioelement noch nicht bereit");
      return;
    }

    if (tracks.length === 0) {
      wsLog("warn", "DOWN ignoriert: Keine Tracks geladen");
      return;
    }

    const primeEnd = await primeCurrentTrack();
    const readyMs = primeEnd ?? performance.now();
    wsLog("info", "GPIO bereit zum Abspielen", {
      elapsedMs: (readyMs - receivedAt).toFixed(1),
      track: currentTrack()?.name ?? "unbekannt",
    });

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

  // Recalc, wenn Tracks oder Index sich Ã¤ndern
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
      window.removeEventListener("resize", handleResize);
      ws?.close();
    };
  });
</script>

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
                Kein Track gewÃ¤hlt
              {/if}
            </span>
          </span>
        </h2>
      </header>

      <audio
        bind:this={audioElement}
        src={tracks.length > 0 ? tracks[currentIndex].url : undefined}
        preload="auto"
        on:loadedmetadata={onLoadedMetadata}
        on:timeupdate={onTimeUpdate}
        on:play={handlePlay}
        on:pause={handlePause}
        on:ended={onEnded}
      ></audio>

      <div class="control-buttons">
        <button on:click={goPrevTrack} disabled={tracks.length === 0}>
          ⏮
        </button>

        <button on:click={() => togglePlay("ui")} disabled={tracks.length === 0}>
          {isPlaying ? "⏸" : "▶"}
        </button>

        <button on:click={goNextTrack} disabled={tracks.length === 0}>
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
        disabled={tracks.length === 0}
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

      {#if dirError}
        <p class="dir-error">{dirError}</p>
      {/if}

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
        <p class="no-folder-text">Noch kein Ordner gewÃ¤hlt.</p>
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
            Keine .wav-Dateien im gewÃ¤hlten Ordner gefunden.
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
</main>
