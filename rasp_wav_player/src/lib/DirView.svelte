<script lang="ts" context="module">
  export interface Track {
    name: string;
    url: string;
  }

  export interface DirNode {
    name: string;
    path: string;       // Pfad relativ zum gewählten Root ("" für Root)
    children: DirNode[];
    wavCount: number;
    tracks?: Track[];   // WAVs direkt in diesem Ordner
  }
</script>

<script lang="ts">
  import { createEventDispatcher } from "svelte";

  export let directories: import("./DirView.svelte").DirNode[] = [];
  export let selectedDirPath: string | null = null;
  export let rootDirName: string = ""; // Name des Ursprungsfolders

  const dispatch = createEventDispatcher<{ select: string }>();

  function handleClick(path: string) {
    dispatch("select", path);
  }

  // Label, das im Ordner-Panel angezeigt wird
  function displayPath(dir: import("./DirView.svelte").DirNode): string {
    // Root: Ursprungsfolder-Name anzeigen
    if (!dir.path) {
      return rootDirName || dir.name || "(Root)";
    }
    // Unterordner: relativer Pfad ab Root
    return dir.path;
  }

  // Tooltip mit vollem Pfad inkl. Ursprungsfolder
  function fullDirPath(dir: import("./DirView.svelte").DirNode): string {
    if (!rootDirName) {
      // Fallback falls aus irgendeinem Grund leer
      return dir.path || dir.name;
    }
    if (!dir.path) {
      return rootDirName;
    }
    return `${rootDirName}/${dir.path}`;
  }
</script>

<ul class="dir-list">
  {#each directories as dir}
    <li class="dir-item">
      <button
        type="button"
        class="dir-entry {dir.path === selectedDirPath ? 'dir-entry-active' : ''}"
        on:click={() => handleClick(dir.path)}
        title={fullDirPath(dir)}
      >
        <span class="dir-name">
          📁 {displayPath(dir)}
        </span>
      </button>
    </li>
  {/each}
</ul>
