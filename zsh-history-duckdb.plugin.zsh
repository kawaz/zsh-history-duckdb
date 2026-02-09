# zsh-history-duckdb: Record shell history in DuckDB with parquet archiving and fzf search

[[ -o interactive ]] || return 0
(( $+commands[duckdb] )) || return 0

export ZSH_HISTORY_DUCKDB="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-history/zsh-history.duckdb"
export ZSH_HISTORY_PARQUET="${ZSH_HISTORY_DUCKDB:h}/parquet"
_zsh_history_cmd="${0:h}/bin/zsh-history-duckdb"
_zsh_history_rowid=
_zsh_history_lock="${ZSH_HISTORY_DUCKDB}.lock"

# ファイルロック (macOS: lockf, Linux: flock)
_zsh_history_flock() {
  if (( $+commands[lockf] )); then
    lockf -t 5 "$_zsh_history_lock" "$@"
  elif (( $+commands[flock] )); then
    flock -w 5 "$_zsh_history_lock" "$@"
  else
    "$@"
  fi
}

_zsh_history_duckdb() {
  _zsh_history_flock duckdb -init /dev/null "$ZSH_HISTORY_DUCKDB" "$@"
}

# 古いデータを parquet にアーカイブ
_zsh_history_archive() {
  [[ -f $ZSH_HISTORY_DUCKDB ]] || return 0
  # 最小日付が1日以上前かチェック
  local should_archive=$(_zsh_history_duckdb -noheader -list <<<"SELECT min(ts) < now() - INTERVAL '1 day' FROM history;" 2>/dev/null)
  [[ $should_archive != "true" ]] && return 0
  # アーカイブ実行
  local uid=$(date +%Y-%m-%dT%H-%M-%S.%N.$$)
  local parquet_dir="${ZSH_HISTORY_PARQUET}"
  local backup_dir="${ZSH_HISTORY_DUCKDB:h}/backup-duckdb"
  local parquet_path="$parquet_dir/zsh-history-$uid.parquet"
  local parquet_path_escaped="${parquet_path//\'/\'\'}"
  local seed_path="$parquet_dir/.seed.parquet"
  local seed_path_escaped="${seed_path//\'/\'\'}"
  mkdir -p "$parquet_dir" "$backup_dir"
  _zsh_history_duckdb <<<"COPY history TO '$parquet_path_escaped' (FORMAT PARQUET, COMPRESSION ZSTD);" || return 1
  # 最後の1行をseedとして保存（次回初期化時にID連続性を確保）
  _zsh_history_duckdb <<<"COPY (SELECT * FROM history ORDER BY id DESC LIMIT 1) TO '$seed_path_escaped' (FORMAT PARQUET, COMPRESSION ZSTD);"
  mv "$ZSH_HISTORY_DUCKDB" "$backup_dir/zsh-history.duckdb.$uid"
  _zsh_history_init
}

# テーブル作成（DuckDB が存在しない場合のみ）
_zsh_history_init() {
  [[ -f $ZSH_HISTORY_DUCKDB ]] && return
  mkdir -p "${ZSH_HISTORY_DUCKDB:h}"
  local seed_path="$ZSH_HISTORY_PARQUET/.seed.parquet"
  # seedがないがparquetアーカイブがある場合、parquetからseedを生成
  if [[ ! -f $seed_path ]] && [[ -d $ZSH_HISTORY_PARQUET ]] && ls "$ZSH_HISTORY_PARQUET"/*.parquet &>/dev/null; then
    mkdir -p "$ZSH_HISTORY_PARQUET"
    local parquet_escaped="${ZSH_HISTORY_PARQUET//\'/\'\'}"
    local seed_escaped="${seed_path//\'/\'\'}"
    duckdb -init /dev/null <<<"COPY (SELECT * FROM read_parquet('${parquet_escaped}/*.parquet') ORDER BY id DESC LIMIT 1) TO '${seed_escaped}' (FORMAT PARQUET, COMPRESSION ZSTD);"
  fi
  _zsh_history_duckdb <<'SQL'
CREATE TABLE IF NOT EXISTS history (
  id INTEGER PRIMARY KEY,
  ts TIMESTAMPTZ DEFAULT now(),
  duration DOUBLE,
  status INTEGER,
  tty TEXT,
  pid INTEGER,
  ppid INTEGER,
  pwd TEXT,
  command TEXT
);
SQL
  # seedがあればインポートしてID連続性を確保
  if [[ -f $seed_path ]]; then
    local seed_escaped="${seed_path//\'/\'\'}"
    _zsh_history_duckdb <<<"INSERT INTO history SELECT * FROM read_parquet('${seed_escaped}');"
  fi
}
_zsh_history_init

_zsh_history_preexec() {
  local cmd=$1
  # cd コマンドの引数を絶対パスに変換（$変数や演算子を含まない場合のみ）
  local -a words=("${(@Q)${(z)cmd}}")
  if [[ ${words[1]} == "cd" && ${#words} -ge 2 && ! ${words[2]} =~ '[$]|^(&&|\|\||;|\|)$' ]]; then
    local arg=${words[2]}
    case $arg in
      -)    arg=$OLDPWD ;;
      ~)    arg=$HOME ;;
      ~/*)  arg="$HOME/${arg#\~/}" ;;
    esac
    local abs=${arg:a}
    if [[ -n $abs ]]; then
      words[2]=${(q)abs}
      cmd="${words[*]}"
    fi
  fi
  _zsh_history_rowid=$(
    _H_TTY=$TTY _H_PWD=${PWD:a} _H_CMD=$cmd _H_PID=$$ _H_PPID=$PPID \
    _zsh_history_duckdb -noheader -list <<<"INSERT INTO history (id, tty, pid, ppid, pwd, command) VALUES ((SELECT COALESCE(MAX(id), 0) + 1 FROM history), getenv('_H_TTY'), getenv('_H_PID')::INTEGER, getenv('_H_PPID')::INTEGER, getenv('_H_PWD'), trim(getenv('_H_CMD'))) RETURNING id;"
  )
}

_zsh_history_precmd() {
  local last_status=$?
  [[ -z $_zsh_history_rowid ]] && return
  _H_STATUS=$last_status _H_ROWID=$_zsh_history_rowid \
  _zsh_history_duckdb <<<"UPDATE history SET duration = epoch(now()) - epoch(ts), status = getenv('_H_STATUS')::INTEGER WHERE id = getenv('_H_ROWID')::INTEGER AND duration IS NULL;"
  _zsh_history_rowid=
}

preexec_functions+=( _zsh_history_preexec )
precmd_functions+=( _zsh_history_precmd )

# 現在 ^R にバインドされている widget を保存してチェイン
typeset -g _zsh_history_search_orig="${${$(bindkey '^R')##* }:-history-incremental-search-backward}"
zle -A "$_zsh_history_search_orig" ._zsh_history_search_orig 2>/dev/null

# fzf で履歴検索 (Ctrl-R)
_zsh_history_search_widget() {
  (( $+commands[duckdb] )) || { zle ._zsh_history_search_orig; return }
  _zsh_history_archive  # 古いデータがあればアーカイブ
  local cmd
  cmd=$(FZF_QUERY=$BUFFER "$_zsh_history_cmd" search)
  if [[ -n $cmd ]]; then
    BUFFER=$cmd
    CURSOR=${#BUFFER}
  fi
  zle reset-prompt
}
zle -N _zsh_history_search_widget
bindkey '^R' _zsh_history_search_widget
