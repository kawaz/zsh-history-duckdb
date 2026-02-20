# zsh-history-duckdb

Zsh plugin that records command history in [DuckDB](https://duckdb.org/), automatically archives old data to Parquet format, and provides interactive search with [fzf](https://github.com/junegunn/fzf).

## Features

- **DuckDB-powered history** -- Fast SQL-based command history storage
- **Parquet auto-archiving** -- Old entries are automatically archived to compressed Parquet files (ZSTD)
- **fzf interactive search** -- Browse and select from your history with fuzzy matching
- **Execution metadata** -- Records duration, exit status, PID, TTY, and working directory for each command
- **Keybindings**
  - `Ctrl-R` -- Search history
  - `Ctrl-D` -- Delete selected entry
  - `Ctrl-F` -- Toggle pwd filter (show only commands from current directory)
  - `Ctrl-P` -- Cycle preview position (right / up / hidden)

## Requirements

- [duckdb](https://duckdb.org/)
- [fzf](https://github.com/junegunn/fzf)

## Installation

### Manual

```bash
git clone https://github.com/kawaz/zsh-history-duckdb.git
source zsh-history-duckdb/zsh-history-duckdb.plugin.zsh
```

### zinit

```zsh
zinit light kawaz/zsh-history-duckdb
```

### sheldon

```bash
sheldon add zsh-history-duckdb --github kawaz/zsh-history-duckdb
```

### Nix home-manager

```nix
{
  programs.zsh.initExtra = ''
    source ${pkgs.fetchFromGitHub {
      owner = "kawaz";
      repo = "zsh-history-duckdb";
      rev = "main";
      hash = ""; # replace with actual hash
    }}/zsh-history-duckdb.plugin.zsh
  '';
}
```

## License

MIT License - Yoshiaki Kawazu ([@kawaz](https://github.com/kawaz))
