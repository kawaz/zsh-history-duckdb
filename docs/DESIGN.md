# Design Document

## Architecture

2 file structure:

| File | Role |
|------|------|
| `zsh-history-duckdb.plugin.zsh` | Plugin entry point. Hooks into `preexec`/`precmd` to record history, binds `Ctrl-R`, manages DB init and archiving. |
| `bin/zsh-history-duckdb` | Standalone executable. Handles search UI (fzf), list, preview, delete. |

## Why `bin/` is a Separate Executable

fzf's `become:` replaces itself via `exec`, and `execute-silent()` invokes an external command. Both require a file path, not a zsh function. The search command recursively calls itself for:

- `preview {id}` -- fzf preview pane
- `delete {id}` + `reload` -- delete entry and refresh list
- `search-toggle-pwd` / `search-toggle-preview` -- `become:` to restart with toggled state

Design rationale: `$SELF` is captured at script top-level (`${0:a}`) because `$0` inside a function resolves to the function name, not the script path.

## Why DuckDB + Parquet

DuckDB is an OLAP-oriented embedded database optimized for analytical queries over columnar data. Parquet is a columnar format with excellent compression -- real-world measurement showed **752 MB of raw history compressing to 54 KB** with ZSTD. This combination makes zsh history both searchable in real time and efficiently archivable long-term.

## DuckDB + Parquet Data Model

```
~/.cache/zsh-history/
  zsh-history.duckdb       # Active history (current session window)
  parquet/
    zsh-history-*.parquet  # Archived history (ZSTD compressed)
    .seed.parquet          # Last row from previous DB (for ID continuity)
  backup-duckdb/           # Pre-archive DB backups
```

**Why this split:**

- DuckDB handles current writes with full ACID. Archiving to Parquet keeps the active DB small and fast.
- Archive trigger: when `min(ts) > 1 day ago`. The entire DB is exported to a new Parquet file, then the DB file is replaced.
- Queries use a `TEMP VIEW all_history` that unions `history` table with `read_parquet('*.parquet')`, so search covers all data transparently.

**ID continuity:** After archiving, a `.seed.parquet` (last row) is imported into the fresh DB so `COALESCE(MAX(id), 0) + 1` generates sequential IDs across archive boundaries.

Design rationale: DuckDB's `SEQUENCE` was originally used for ID generation, but archiving replaces the DB file entirely, which destroys the sequence state and causes ID collisions. The `MAX(id)+1` approach with `.seed.parquet` eliminates this class of bugs by deriving the next ID from the data itself.

## State Passing via Environment Variables

fzf's `become:` replaces the process via `exec`. State must survive across `exec` boundaries:

| Variable | Purpose |
|----------|---------|
| `_ZSH_HIST_PWD_FILTER` | Current pwd filter state (set = ON, unset = OFF). Toggled by `Ctrl-F`. |
| `_ZSH_HIST_PREVIEW` | Preview pane position (`right` / `up` / `hidden`). Cycled by `Ctrl-P`. |
| `FZF_QUERY` | Passes current BUFFER content as initial query to fzf. |

Toggle commands (`search-toggle-pwd`, `search-toggle-preview`) flip the env var and `exec "$SELF" search` to restart fzf with the new state.

## SQL Injection Prevention

All user-controlled values (command text, pwd, id, status) are passed via `getenv()` in SQL rather than string interpolation. This avoids shell quoting issues and SQL injection.

## Concurrency

Multiple zsh sessions write to the same DuckDB file. DuckDB does not officially support concurrent writes from multiple processes, so file locking (`lockf` on macOS, `flock` on Linux) serializes access with a 5-second timeout. The bin script uses read-only mode (`-readonly`) for queries that don't modify data.

## History Recording

`preexec` inserts a row with `duration=NULL, status=NULL` (command running). `precmd` updates the row with actual duration and exit status. This captures commands that are interrupted or crash.

`cd` arguments are normalized to absolute paths at record time so pwd-based filtering works reliably even after the directory is renamed or relative paths are used.
