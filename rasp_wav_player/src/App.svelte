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
  let isPriming = false;
  let primePromise: Promise<number | null> | null = null;
  let primeRunId = 0;
  let playStartWatchdogId: number | null = null;
  let lastPlayStartPosition = 0;
  let suppressPauseEventUntilMs = 0;
  let lastWatchdogStage: 0 | 1 | 2 = 0;
  let firstPlayGraceConsumedAttemptId: number | null = null;
  let stage0MetadataGateConsumedAttemptId: number | null = null;
  let hasPlaybackProgress = false;
  let warmupRunId = 0;
  let isCurrentTrackWarming = false;
  let isCurrentTrackWarmReady = false;
  let currentTrackWarmKey: string | null = null;
  const PRIME_TIMEOUT_MS = 300;
  const STALL_CHECK_MS = 650;
  const FIRST_PLAY_EXTRA_GRACE_MS = 900;
  const STAGE0_METADATA_GATE_MS = 300;
  const WARMUP_METADATA_TIMEOUT_MS = 2000;

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

  const currentWarmupKey = (): string | null => {
    const track = currentTrack();
    if (!track) return null;
    return `${preloadRunId}:${currentIndex}:${track.name}`;
  };

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

  function ensureAudioSourceForCurrentTrack(): boolean {
    if (!audioElement) return false;
    const track = currentTrack();
    if (!track?.ramUrl) return false;

    if (audioElement.src !== track.ramUrl) {
      audioElement.src = track.ramUrl;
    }
    return true;
  }

  function hasBufferedAudio(): boolean {
    if (!audioElement) return false;
    try {
      const buffered = audioElement.buffered;
      if (!buffered || buffered.length === 0) return false;
      const end = buffered.end(buffered.length - 1);
      return Number.isFinite(end) && end > 0;
    } catch (_err) {
      return false;
    }
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

  function clearPlayStartWatchdog(): void {
    if (playStartWatchdogId !== null) {
      window.clearTimeout(playStartWatchdogId);
      playStartWatchdogId = null;
    }
  }

  async function createTrackObjectUrl(
    fileHandle: FileSystemFileHandle,
  ): Promise<string> {
    const file = await fileHandle.getFile();
    const mime = file.type.trim();
    if (mime) {
      return URL.createObjectURL(file);
    }

    // Some File System Access handles report empty MIME for WAV files.
    const buffer = await file.arrayBuffer();
    const blob = new Blob([buffer], { type: "audio/wav" });
    return URL.createObjectURL(blob);
  }

  function resetPlaybackForTrackTransition(options?: {
    clearSource?: boolean;
  }): void {
    cancelPendingPlayAttempt();
    clearPlayStartWatchdog();
    primeRunId += 1;
    warmupRunId += 1;
    isPlaying = false;
    hasPlaybackProgress = false;
    firstPlayGraceConsumedAttemptId = null;
    stage0MetadataGateConsumedAttemptId = null;
    isCurrentTrackWarming = false;
    isCurrentTrackWarmReady = false;
    currentTrackWarmKey = null;
    currentTime = 0;
    duration = 0;
    playError = null;
    clearFallbackDirectUrl();

    if (!audioElement) return;
    audioElement.pause();
    if (options?.clearSource) {
      audioElement.removeAttribute("src");
    }
    audioElement.load();
    audioElement.volume = volume;
  }

  async function primeCurrentTrack(): Promise<number | null> {
    if (!audioElement || tracks.length === 0) {
      wsLog("warn", "Prime übersprungen: Kein Audioelement/keine Tracks");
      return null;
    }

    if (primePromise) return primePromise;
    if (!audioElement.paused) {
      wsLog("info", "Prime übersprungen: Bereits in Wiedergabe");
      return null;
    }

    const track = currentTrack();
    if (!track) return null;
    const runId = primeRunId;

    primePromise = (async () => {
      const start = performance.now();
      const trackName = track.name ?? "unbekannt";
      wsLog("info", "Prime gestartet", { track: trackName });
      let previousVolume: number | null = null;
      let previousMuted: boolean | null = null;
      let previousTime: number | null = null;

      try {
        isPriming = true;
        previousVolume = audioElement.volume;
        previousMuted = audioElement.muted;
        previousTime = Number.isFinite(audioElement.currentTime)
          ? audioElement.currentTime
          : 0;

        audioElement.preload = "auto";
        if (audioElement.readyState < 3 || !hasBufferedAudio()) {
          audioElement.load();
        }

        audioElement.muted = true;
        audioElement.volume = 0;
        const playPromise = audioElement.play();
        if (playPromise) {
          const guardedPlayPromise = playPromise.catch((_err) => {
            // Expected when priming gets interrupted by pause/track changes.
          });
          const timeoutPromise = new Promise<void>((resolve) => {
            window.setTimeout(resolve, PRIME_TIMEOUT_MS);
          });
          await Promise.race([guardedPlayPromise, timeoutPromise]);
          if (runId !== primeRunId) {
            wsLog("info", "Prime invalidated by track/dir change", {
              track: trackName,
            });
            return performance.now();
          }
          if (audioElement.paused) {
            wsLog("warn", "Prime timeout reached", {
              track: trackName,
              timeoutMs: PRIME_TIMEOUT_MS,
            });
          }
        }
        // Always call pause once to abort any pending play() from priming.
        suppressPauseEventUntilMs = performance.now() + 1000;
        audioElement.pause();
      } catch (err) {
        wsLog("warn", "Prime fehlgeschlagen", err);
      } finally {
        if (audioElement) {
          if (runId !== primeRunId) {
            wsLog("info", "Prime invalidated by track/dir change", {
              track: trackName,
            });
            isPriming = false;
            primePromise = null;
            return performance.now();
          }
          try {
            audioElement.muted = previousMuted ?? false;
            const restoreVolume =
              previousVolume !== null && Number.isFinite(previousVolume)
                ? previousVolume
                : volume;
            audioElement.volume = restoreVolume;
            if (previousTime !== null && Number.isFinite(previousTime)) {
              audioElement.currentTime = previousTime;
            }
          } catch (_restoreErr) {
            // ignore restore failures; playback path handles actual errors
          }
        }
        isPriming = false;
        primePromise = null;
        wsLog("info", "Prime beendet", {
          track: trackName,
          durationMs: (performance.now() - start).toFixed(1),
        });
      }

      return performance.now();
    })();

    return primePromise;
  }

  async function warmupCurrentTrackForInstantPlay(runId: number): Promise<void> {
    if (runId !== warmupRunId) return;
    if (!audioElement || isPlaying || isPlayStarting) return;
    const track = currentTrack();
    if (!track?.ramUrl) return;

    const key = currentWarmupKey();
    if (!key) return;
    if (isCurrentTrackWarmReady && currentTrackWarmKey === key) return;
    if (isCurrentTrackWarming && currentTrackWarmKey === key) return;

    isCurrentTrackWarming = true;
    isCurrentTrackWarmReady = false;
    currentTrackWarmKey = key;

    wsLog("info", "Warmup gestartet", {
      track: track.name,
      key,
    });

    try {
      if (!ensureAudioSourceForCurrentTrack()) {
        wsLog("warn", "Warmup abgebrochen: Quelle nicht bereit", {
          track: track.name,
          key,
        });
        return;
      }
      audioElement.preload = "auto";
      audioElement.load();

      const metadataSignal = await new Promise<
        "event" | "timeout" | "already-ready"
      >((resolve) => {
        if (!audioElement) {
          resolve("timeout");
          return;
        }
        if (audioElement.readyState >= 1) {
          resolve("already-ready");
          return;
        }

        let settled = false;
        const settle = (signal: "event" | "timeout") => {
          if (settled) return;
          settled = true;
          audioElement?.removeEventListener("loadedmetadata", onReady);
          audioElement?.removeEventListener("canplay", onReady);
          resolve(signal);
        };
        const onReady = () => settle("event");

        audioElement.addEventListener("loadedmetadata", onReady, { once: true });
        audioElement.addEventListener("canplay", onReady, { once: true });
        window.setTimeout(() => settle("timeout"), WARMUP_METADATA_TIMEOUT_MS);
      });

      if (!audioElement) return;
      if (runId !== warmupRunId || key !== currentTrackWarmKey) {
        wsLog("info", "Warmup invalidated by track/dir change", { key });
        return;
      }

      const metadataReady = audioElement.readyState >= 1;
      if (!metadataReady) {
        wsLog("warn", "Warmup metadata timeout", {
          track: track.name,
          key,
          readyState: audioElement.readyState,
          signal: metadataSignal,
          timeoutMs: WARMUP_METADATA_TIMEOUT_MS,
        });
        return;
      }

      wsLog("info", "Warmup metadata ready", {
        track: track.name,
        readyState: audioElement.readyState,
        signal: metadataSignal,
      });

      await primeCurrentTrack();
      if (runId !== warmupRunId || key !== currentTrackWarmKey) {
        wsLog("info", "Warmup invalidated by track/dir change", { key });
        return;
      }

      if (audioElement.readyState < 1) {
        wsLog("warn", "Warmup prime finished without metadata", {
          track: track.name,
          key,
          readyState: audioElement.readyState,
        });
        return;
      }

      wsLog("info", "Warmup prime done", { track: track.name });
      isCurrentTrackWarmReady = true;
      wsLog("info", "Warmup ready for instant play", {
        track: track.name,
        key,
      });
    } catch (err) {
      wsLog("warn", "Warmup fehlgeschlagen", err);
    } finally {
      if (runId === warmupRunId && key === currentTrackWarmKey) {
        isCurrentTrackWarming = false;
      }
    }
  }

  function schedulePlayStartWatchdog(
    source: "ui" | "gpio" | "other",
    attemptId: number,
    stage: 0 | 1 | 2,
    delayMs = STALL_CHECK_MS,
  ): void {
    if (!audioElement) return;
    clearPlayStartWatchdog();
    lastWatchdogStage = stage;

    lastPlayStartPosition = audioElement.currentTime;
    playStartWatchdogId = window.setTimeout(() => {
      void (async () => {
        if (!audioElement) return;
        if (attemptId !== playAttemptId) return;
        if (!isPlaying || audioElement.paused || isPriming) return;

        const nowPosition = audioElement.currentTime;
        const delta = Math.abs(nowPosition - lastPlayStartPosition);
        if (delta > 0.02) {
          if (stage > 0) {
            wsLog("info", "Playback stall recovery result", {
              source,
              result: "recovered",
              stage,
              delta: delta.toFixed(3),
            });
          }
          return;
        }

        if (
          stage === 0 &&
          audioElement.readyState === 0 &&
          !isCurrentTrackWarmReady &&
          stage0MetadataGateConsumedAttemptId !== attemptId
        ) {
          stage0MetadataGateConsumedAttemptId = attemptId;
          wsLog("info", "Stage0 metadata gate before stall", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
            attemptId,
            gateMs: STAGE0_METADATA_GATE_MS,
          });
          audioElement.preload = "auto";
          audioElement.load();
          schedulePlayStartWatchdog(
            source,
            attemptId,
            stage,
            STAGE0_METADATA_GATE_MS,
          );
          return;
        }

        if (
          stage === 0 &&
          !hasPlaybackProgress &&
          firstPlayGraceConsumedAttemptId !== attemptId
        ) {
          firstPlayGraceConsumedAttemptId = attemptId;
          wsLog("info", "First-play grace before stall recovery", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
            attemptId,
            extraMs: FIRST_PLAY_EXTRA_GRACE_MS,
          });
          schedulePlayStartWatchdog(
            source,
            attemptId,
            stage,
            FIRST_PLAY_EXTRA_GRACE_MS,
          );
          return;
        }

        wsLog("warn", "Playback stall detected", {
          source,
          stage,
          positionBefore: lastPlayStartPosition.toFixed(3),
          positionNow: nowPosition.toFixed(3),
          readyState: audioElement.readyState,
          networkState: audioElement.networkState,
        });
        await recoverFromPlaybackStall(source, stage);
      })();
    }, delayMs);
  }

  async function recoverFromPlaybackStall(
    source: "ui" | "gpio" | "other",
    stage: 0 | 1 | 2,
  ): Promise<void> {
    if (!audioElement) return;
    const track = currentTrack();
    if (!track) return;
    clearPlayStartWatchdog();

    if (stage >= 2) {
      playError = "Playback stalled repeatedly after retries";
      isPlayStarting = false;
      isPlaying = false;
      audioElement.muted = false;
      audioElement.volume = volume;
      wsLog("error", "Playback stall recovery failed", {
        source,
        track: track.name,
        stage,
        result: "failed",
      });
      return;
    }

    cancelPendingPlayAttempt();
    if (!audioElement.paused) {
      audioElement.pause();
    }
    audioElement.currentTime = 0;

    try {
      if (stage === 0) {
        wsLog("warn", "Retry play from RAM URL", { track: track.name, stage });
        if (track.ramUrl) {
          audioElement.src = track.ramUrl;
        }
      } else {
        wsLog("warn", "Retry play with direct URL fallback", {
          track: track.name,
          stage,
        });
        clearFallbackDirectUrl();
        const fallbackUrl = await createTrackObjectUrl(track.fileHandle);
        if (!audioElement) {
          URL.revokeObjectURL(fallbackUrl);
          return;
        }
        fallbackDirectUrl = fallbackUrl;
        audioElement.src = fallbackDirectUrl;
      }

      audioElement.load();
      await primeCurrentTrack();
      audioElement.muted = false;
      audioElement.volume = volume;
    } catch (err) {
      if (audioElement) {
        audioElement.muted = false;
        audioElement.volume = volume;
      }
      wsLog("error", "Playback stall recovery preparation failed", err);
      return;
    }

    if (!audioElement) return;
    const retryStartedAt = performance.now();
    lastPlayTrigger = source;
    lastPlayCallTs = retryStartedAt;
    playRequestedExplicitly = true;
    playError = null;
    playAttemptId += 1;
    const retryAttemptId = playAttemptId;
    const nextStage: 1 | 2 = stage === 0 ? 1 : 2;
    void tryPlayWithOptionalFallback(source, retryStartedAt, retryAttemptId, nextStage);
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

        if (runId !== preloadRunId || preloadMode !== "rolling") return;
        const url = await createTrackObjectUrl(track.fileHandle);
        if (runId !== preloadRunId || preloadMode !== "rolling") {
          URL.revokeObjectURL(url);
          return;
        }
        track.ramUrl = url;
        track.preloaded = true;
      }

      if (runId !== preloadRunId || preloadMode !== "rolling") return;
      pruneRamCacheToWindow(keep);
      setRollingProgress(centerIndex);
      tracks = [...tracks];
      if (
        audioElement &&
        centerIndex === currentIndex &&
        currentTrack()?.ramUrl &&
        !isPlaying &&
        !isPlayStarting
      ) {
        void warmupCurrentTrackForInstantPlay(warmupRunId);
      }
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

        const url = await createTrackObjectUrl(track.fileHandle);
        if (runId !== preloadRunId) {
          URL.revokeObjectURL(url);
          clearRamUrlsForTracks(trackList);
          return;
        }
        track.ramUrl = url;
        track.preloaded = true;
        preloadProgressCount += 1;

        // Trigger reactivity for progress and per-track readiness.
        tracks = [...tracks];
      }
      if (runId === preloadRunId && audioElement && currentTrack()?.ramUrl) {
        void warmupCurrentTrackForInstantPlay(warmupRunId);
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
    clearPlayStartWatchdog();
    primeRunId += 1;
    suppressPauseEventUntilMs = 0;
    firstPlayGraceConsumedAttemptId = null;
    stage0MetadataGateConsumedAttemptId = null;
  }

  async function tryPlayWithOptionalFallback(
    source: "ui" | "gpio" | "other",
    startedAt: number,
    attemptId: number,
    watchdogStage: 0 | 1 | 2 = 0,
  ): Promise<void> {
    if (!audioElement || !currentTrack()) return;

    isPlayStarting = true;
    audioElement.muted = false;
    audioElement.volume = volume;

    try {
      const playPromise = audioElement.play();
      if (playPromise) {
        await playPromise;
      }
      if (attemptId !== playAttemptId) return;

      isPlayStarting = false;
      playError = null;
      playRequestedExplicitly = false;
      const resolvedAt = performance.now();
      wsLog("info", "Play-Promise erfuellt", {
        source,
        track: currentTrack()?.name ?? "unbekannt",
        dtMs: (resolvedAt - startedAt).toFixed(1),
        sinceWsMs:
          lastWsDownTs !== null ? (resolvedAt - lastWsDownTs).toFixed(1) : undefined,
      });
      schedulePlayStartWatchdog(source, attemptId, watchdogStage);
      return;
    } catch (err) {
      if (attemptId !== playAttemptId) return;
      isPlayStarting = false;

      if (err instanceof DOMException && err.name === "AbortError") {
        playError = null;
        if (audioElement) {
          audioElement.muted = false;
          audioElement.volume = volume;
        }
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
          if (audioElement) {
            audioElement.muted = false;
            audioElement.volume = volume;
          }
          return;
        }

        clearFallbackDirectUrl();
        if (attemptId !== playAttemptId || !audioElement) return;
        const url = await createTrackObjectUrl(track.fileHandle);
        if (attemptId !== playAttemptId || !audioElement) {
          URL.revokeObjectURL(url);
          return;
        }
        fallbackDirectUrl = url;
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
        playRequestedExplicitly = false;
        wsLog("info", "Fallback-Play erfolgreich", {
          source,
          track: track.name,
        });
        schedulePlayStartWatchdog(source, attemptId, 2);
      } catch (fallbackErr) {
        if (attemptId !== playAttemptId) return;
        isPlayStarting = false;
        if (
          fallbackErr instanceof DOMException &&
          fallbackErr.name === "AbortError"
        ) {
          playError = null;
          if (audioElement) {
            audioElement.muted = false;
            audioElement.volume = volume;
          }
          wsLog("info", "Fallback-Play abgebrochen (erwartet)", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
          });
          return;
        }
        const fallbackErrorText = describePlayError(fallbackErr);
        playError = `Playback failed: ${initialErrorText} | fallback failed: ${fallbackErrorText}`;
        playRequestedExplicitly = false;
        if (audioElement) {
          audioElement.muted = false;
          audioElement.volume = volume;
        }
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
      const sourceReady = ensureAudioSourceForCurrentTrack();
      if (!sourceReady) {
        wsLog("warn", "Play angefordert, aber Quelle nicht gesetzt", {
          source,
          track: currentTrack()?.name ?? "unbekannt",
        });
      }
      const warmKey = currentWarmupKey();
      const canSkipPrime =
        sourceReady &&
        Boolean(warmKey) &&
        isCurrentTrackWarmReady &&
        currentTrackWarmKey === warmKey;
      void (async () => {
        if (canSkipPrime) {
          wsLog("info", "Warmup ready: skip prime for instant play", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
          });
          if (attemptId !== playAttemptId || !audioElement) return;
          audioElement.muted = false;
          audioElement.volume = volume;
          void tryPlayWithOptionalFallback(source, now, attemptId, 0);
          return;
        }
        const primeStartedAt = performance.now();
        await primeCurrentTrack();
        if (attemptId !== playAttemptId) return;
        if (!audioElement) return;
        const primeElapsedMs = performance.now() - primeStartedAt;
        if (primeElapsedMs >= PRIME_TIMEOUT_MS) {
          wsLog("info", "Play continues after prime timeout", {
            source,
            track: currentTrack()?.name ?? "unbekannt",
            elapsedMs: primeElapsedMs.toFixed(1),
            timeoutMs: PRIME_TIMEOUT_MS,
          });
        }
        audioElement.muted = false;
        audioElement.volume = volume;
        void tryPlayWithOptionalFallback(source, now, attemptId, 0);
      })();
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
    if (currentTime > 0.02) {
      hasPlaybackProgress = true;
    }
  }

  function handlePlay(): void {
    if (!audioElement) return;
    if (isPriming) {
      wsLog("info", "Playback-Event während Prime (stumm)", {
        track: currentTrack()?.name ?? "unbekannt",
      });
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
    if (playStartWatchdogId === null) {
      schedulePlayStartWatchdog(
        lastPlayTrigger ?? "other",
        playAttemptId,
        lastWatchdogStage,
      );
    }
  }

  function handlePause(): void {
    if (!audioElement) return;
    if (isPriming) {
      wsLog("info", "Pause-Event während Prime (stumm)", {
        track: currentTrack()?.name ?? "unbekannt",
      });
      return;
    }
    const now = performance.now();
    if (isPlayStarting && now <= suppressPauseEventUntilMs) {
      wsLog("info", "Prime-induziertes Pause-Event ignoriert", {
        track: currentTrack()?.name ?? "unbekannt",
        dtMs: (suppressPauseEventUntilMs - now).toFixed(1),
      });
      return;
    }
    playRequestedExplicitly = false;
    isPlayStarting = false;
    clearPlayStartWatchdog();
    const trackName = currentTrack()?.name ?? "unbekannt";
    isPlaying = false;
    wsLog("info", "Playback pausiert", {
      track: trackName,
      source: lastPlayTrigger ?? "unbekannt",
      timestampMs: now.toFixed(1),
      position: audioElement.currentTime.toFixed(3),
    });
  }

  function handleAudioError(): void {
    if (!audioElement) return;
    const trackName = currentTrack()?.name ?? "unbekannt";
    const code = audioElement.error?.code ?? null;
    playRequestedExplicitly = false;
    isPlayStarting = false;
    clearPlayStartWatchdog();
    isPlaying = false;
    audioElement.muted = false;
    audioElement.volume = volume;
    playError =
      code === null
        ? "Playback failed: unknown audio element error"
        : `Playback failed: audio element error code ${code}`;
    wsLog("error", "Audio-Element Fehler", {
      track: trackName,
      code,
      readyState: audioElement.readyState,
      networkState: audioElement.networkState,
      currentSrc: audioElement.currentSrc,
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
      resetPlaybackForTrackTransition({ clearSource: true });
      clearRamUrlsForTracks(tracks);

      // Reset State
      tracks = [];
      directoryTree = null;
      directories = [];
      selectedDirPath = null;
      currentIndex = 0;
      preloadError = null;
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
    const runId = preloadRunId;
    clearRamUrlsForTracks(tracks);

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
    resetPlaybackForTrackTransition({ clearSource: true });

    // Playlist-Scroll nach oben, wenn Ordner gewechselt wird
    void scrollPlaylistToTop();

    void preloadDirectoryTracksToRam(tracks, runId);
  }

  function selectTrack(index: number): void {
    if (tracks.length === 0) return;

    wsLog("info", "Track gewählt", {
      track: tracks[index]?.name ?? `Index ${index}`,
    });

    currentIndex = index;
    resetPlaybackForTrackTransition();

    if (preloadMode === "rolling") {
      setRollingProgress(currentIndex);
      void ensureRollingWindowLoaded(currentIndex, preloadRunId);
    } else {
      void warmupCurrentTrackForInstantPlay(warmupRunId);
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
    clearPlayStartWatchdog();
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
    wsLog("info", "GPIO Toggle angefordert (RAM bereit)", {
      track: trackName,
      action: !isPlaying && !isPlayStarting ? "play" : "pause",
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

    const wsProtocol = window.location.protocol === "https:" ? "wss" : "ws";
    const wsUrl = `${wsProtocol}://${window.location.host}/ws`;

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
      warmupRunId += 1;
      cancelPendingPlayAttempt();
      clearPlayStartWatchdog();
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
        on:error={handleAudioError}
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
