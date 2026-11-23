#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

unfixed_file=${IMAGE_SCAN_UNFIXED:-$root/scripts/image-scan-unfixed.txt}
clock_days=30
template=$root/scripts/image-scan.tmpl
declare -A handled_ref=()

list_refs() {
  local base=${IMAGE_SCAN_ROOT:-$root}
  local -a grep_paths=()
  [ -d "$base/modules/workloads" ] && grep_paths+=("$base/modules/workloads")
  [ -d "$base/modules/runtime" ] && grep_paths+=("$base/modules/runtime")
  [ -f "$base/modules/platform/runners.nix" ] && grep_paths+=("$base/modules/platform/runners.nix")
  {
    if [ "${#grep_paths[@]}" -gt 0 ]; then
      grep -RhoE '[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}' \
        "${grep_paths[@]}" || true
    fi
    join_split_refs "$base/modules/workloads" "$base/modules/runtime"
  } | sort -u
}

join_split_refs() {
  local dir file
  shopt -s nullglob globstar
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    for file in "$dir"/**/*.nix; do
      [ -f "$file" ] || continue
      if grep -qE 'imageDigest[[:space:]]*=[[:space:]]*"sha256:[a-f0-9]{64}"' "$file"; then
        join_split_file "$file"
      fi
    done
  done
}

join_split_file() {
  local file=$1 line
  local -a img=() dig=() hasfile=()
  local depth=0 in_mstr=0
  while IFS= read -r line || [ -n "$line" ]; do
    scan_nix_line "$line"
  done <"$file"
}

flush_assignment() {
  local d=$1 buf=$2 value token
  local image_re='(^|[^A-Za-z0-9_])image[[:space:]]*=[[:space:]]*"([^"]*)"'
  local digest_re='(^|[^A-Za-z0-9_])imageDigest[[:space:]]*=[[:space:]]*"(sha256:[a-f0-9]{64})"'
  local file_re='(^|[^A-Za-z0-9_])imageFile[[:space:]]*=[[:space:]]*([^;]+)'
  if [[ "$buf" =~ $image_re ]]; then
    img[d]=${BASH_REMATCH[2]}
  fi
  if [[ "$buf" =~ $digest_re ]]; then
    dig[d]=${BASH_REMATCH[2]}
  fi
  if [[ "$buf" =~ $file_re ]]; then
    value=${BASH_REMATCH[2]}
    token=${value#"${value%%[![:space:]]*}"}
    token=${token%%[[:space:]]*}
    if [ "$token" != "null" ]; then
      hasfile[d]=1
    fi
  fi
}

emit_depth() {
  local d=$1
  local image=${img[d]:-} digest=${dig[d]:-} filemark=${hasfile[d]:-}
  unset "img[d]" "dig[d]" "hasfile[d]"
  [ -n "$image" ] && [ -n "$digest" ] || return 0
  [ -z "$filemark" ] || return 0
  case $image in
    *"@sha256:"*) return 0 ;;
  esac
  [[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]+)?$ ]] || return 0
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || return 0
  printf '%s@%s\n' "$image" "$digest"
}

scan_nix_line() {
  local s=$1 i=0 ch buf="" len n2
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    if [ "$in_mstr" -eq 1 ]; then
      ch=${s:i:1}
      if [ "$ch" = "'" ] && [ $((i + 1)) -lt "$len" ] && [ "${s:i+1:1}" = "'" ]; then
        n2=${s:i+2:1}
        case "$n2" in
          '$' | \\ | "'")
            i=$((i + 3))
            ;;
          *)
            in_mstr=0
            i=$((i + 2))
            ;;
        esac
      else
        i=$((i + 1))
      fi
      continue
    fi
    ch=${s:i:1}
    case $ch in
      '#')
        break
        ;;
      '"')
        buf+="$ch"
        i=$((i + 1))
        while [ "$i" -lt "$len" ]; do
          ch=${s:i:1}
          buf+="$ch"
          i=$((i + 1))
          if [ "$ch" = \\ ]; then
            if [ "$i" -lt "$len" ]; then
              buf+="${s:i:1}"
              i=$((i + 1))
            fi
            continue
          fi
          if [ "$ch" = '"' ]; then
            break
          fi
        done
        ;;
      "'")
        if [ $((i + 1)) -lt "$len" ] && [ "${s:i+1:1}" = "'" ]; then
          in_mstr=1
          i=$((i + 2))
          continue
        fi
        buf+="$ch"
        i=$((i + 1))
        ;;
      '{')
        flush_assignment "$depth" "$buf"
        buf=""
        depth=$((depth + 1))
        i=$((i + 1))
        ;;
      '}')
        flush_assignment "$depth" "$buf"
        buf=""
        emit_depth "$depth"
        if [ "$depth" -gt 0 ]; then
          depth=$((depth - 1))
        fi
        i=$((i + 1))
        ;;
      *)
        buf+="$ch"
        i=$((i + 1))
        ;;
    esac
  done
  if [ "$in_mstr" -eq 0 ]; then
    flush_assignment "$depth" "$buf"
  fi
}

days_from_civil() {
  local y=$1 m=$2 d=$3 era yoe doy doe
  if [ "$m" -le 2 ]; then
    y=$((y - 1))
  fi
  if [ "$y" -ge 0 ]; then
    era=$((y / 400))
  else
    era=$(((y - 399) / 400))
  fi
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then
    doy=$(((153 * (m - 3) + 2) / 5 + d - 1))
  else
    doy=$(((153 * (m + 9) + 2) / 5 + d - 1))
  fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

valid_date() {
  local y m d dim
  case $1 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=$((10#${1%%-*}))
  m=$((10#${1:5:2}))
  d=$((10#${1:8:2}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 1
  [ "$d" -ge 1 ] || return 1
  case $m in
    1 | 3 | 5 | 7 | 8 | 10 | 12) dim=31 ;;
    4 | 6 | 9 | 11) dim=30 ;;
    2)
      if [ $((y % 400)) -eq 0 ] || { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; }; then
        dim=29
      else
        dim=28
      fi
      ;;
    *) return 1 ;;
  esac
  [ "$d" -le "$dim" ]
}

ymd_days() {
  local y m d
  y=$((10#${1%%-*}))
  m=$((10#${1:5:2}))
  d=$((10#${1:8:2}))
  days_from_civil "$y" "$m" "$d"
}

current_digest() {
  local name_tag=$1
  if [ -n "${IMAGE_SCAN_DIGEST_CMD:-}" ]; then
    "$IMAGE_SCAN_DIGEST_CMD" "$name_tag"
    return
  fi
  if ! command -v skopeo > /dev/null 2>&1; then
    echo "image-scan: skopeo is not on PATH" >&2
    return 1
  fi
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://${name_tag}"
}

candidate_accepted() {
  local newref=$1
  local oldref=$2
  local matches cve pref sev state id extra saved ok
  if [ "${IMAGE_SCAN_TRUST_FOLLOW:-}" = 1 ]; then
    return 0
  fi
  if ! command -v grype > /dev/null 2>&1; then
    echo "image-scan: grype is not on PATH" >&2
    return 1
  fi
  if ! matches=$(run_grype "registry:${newref}"); then
    echo "image-scan: grype failed for $newref" >&2
    return 1
  fi
  while read -r cve pref; do
    [ "$pref" = "$oldref" ] || continue
    while read -r sev state id extra; do
      [ -n "$id" ] || continue
      : "$sev" "$state" "$extra"
      if [ "$id" = "$cve" ]; then
        echo "image-scan: candidate still has $cve $newref" >&2
        return 1
      fi
    done <<< "$matches"
  done < "$IMAGE_SCAN_PROPOSE_FILE"
  saved=${IMAGE_SCAN_PROPOSE_FILE-}
  unset IMAGE_SCAN_PROPOSE_FILE
  ok=0
  if ! printf '%s\n' "$matches" | apply_matches "$newref" >&2; then
    echo "image-scan: candidate still failing $newref" >&2
    ok=1
  fi
  if [ -n "$saved" ]; then
    IMAGE_SCAN_PROPOSE_FILE=$saved
  fi
  [ "$ok" -eq 0 ]
}

wipe_dir() {
  local dir=$1 child
  [ -d "$dir" ] || return 0
  shopt -s nullglob dotglob
  for child in "$dir"/*; do
    rm -rf -- "$child" || true
  done
  shopt -u nullglob dotglob
}

scratch_free_bytes() {
  local line avail
  line=$(df -B1 -P "$1" | tail -n 1)
  read -r _ _ _ avail _ <<<"$line"
  printf '%s\n' "$avail"
}

image_bytes() {
  local target=$1 name size
  name=${target#registry:}
  if [ -n "${IMAGE_SCAN_SIZE_CMD:-}" ]; then
    "$IMAGE_SCAN_SIZE_CMD" "$name"
    return
  fi
  command -v skopeo >/dev/null 2>&1 || return 0
  skopeo inspect --no-tags --format '{{.Size}}' "docker://${name}"
}

scratch_can_hold() {
  local target=$1 size avail room half reserve
  reserve=${IMAGE_SCAN_SCRATCH_RESERVE:-4294967296}
  [[ $reserve =~ ^[0-9]+$ ]] || reserve=4294967296
  size=$(image_bytes "$target" 2>/dev/null || true)
  size=${size//$'\r'/}
  size=${size//$'\n'/}
  [[ $size =~ ^[0-9]+$ ]] || return 0
  avail=$(scratch_free_bytes "$IMAGE_SCAN_SCRATCH")
  [[ $avail =~ ^[0-9]+$ ]] || return 0
  if [ "$avail" -le "$reserve" ]; then
    return 1
  fi
  room=$((avail - reserve))
  half=$((room / 2))
  [ "$size" -le "$half" ]
}

run_grype() {
  local target=$1
  local layer_tmp rc scratch
  scratch=${IMAGE_SCAN_SCRATCH:-}
  if [ -n "$scratch" ]; then
    mkdir -p "$scratch/work" "$scratch/db"
    wipe_dir "$scratch/work"
    if ! scratch_can_hold "$target"; then
      echo "image-scan: image does not fit in scratch: $target" >&2
      wipe_dir "$scratch/work"
      return 1
    fi
    set +e
    TMPDIR="$scratch/work" GRYPE_DB_CACHE_DIR="$scratch/db" \
      grype "$target" -o template -t "$template"
    rc=$?
    set -e
    wipe_dir "$scratch/work"
    return "$rc"
  fi
  layer_tmp=$(mktemp -d "${TMPDIR:-/tmp}/image-layers.XXXXXX")
  set +e
  TMPDIR="$layer_tmp" grype "$target" -o template -t "$template"
  rc=$?
  set -e
  rm -rf "$layer_tmp"
  return "$rc"
}

follow_one() {
  local ref=$1
  local base old leaf newdig newref
  base=${ref%@*}
  old=${ref##*@}
  leaf=${base##*/}
  handled_ref[$ref]=1
  if [[ $leaf != *:* ]]; then
    echo "image-scan: no tag to follow $ref" >&2
    echo "image-scan: blocked no-tag $ref"
    return 1
  fi
  if ! newdig=$(current_digest "$base"); then
    echo "image-scan: blocked lookup-failed $ref"
    return 1
  fi
  newdig=${newdig//$'\r'/}
  newdig=${newdig//$'\n'/}
  if [[ ! $newdig =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "image-scan: bad digest for $base" >&2
    echo "image-scan: blocked lookup-failed $ref"
    return 1
  fi
  if [ "$newdig" = "$old" ]; then
    echo "image-scan: tag unchanged $ref" >&2
    echo "image-scan: blocked tag-unchanged $ref"
    return 1
  fi
  newref="${base}@${newdig}"
  if ! candidate_accepted "$newref" "$ref"; then
    echo "image-scan: blocked candidate-still-vulnerable $ref"
    return 1
  fi
  echo "image-scan: replace $ref $newref"
}

follow_proposals() {
  local cve ref
  local -a refs=()
  local -A seen=()
  follow_unresolved=0
  [ -s "${IMAGE_SCAN_PROPOSE_FILE:-}" ] || return 0
  while read -r cve ref; do
    [ -n "$ref" ] || continue
    : "$cve"
    if [ -n "${seen[$ref]:-}" ]; then
      continue
    fi
    seen[$ref]=1
    refs+=("$ref")
  done < "$IMAGE_SCAN_PROPOSE_FILE"
  for ref in "${refs[@]}"; do
    if ! follow_one "$ref"; then
      follow_unresolved=$((follow_unresolved + 1))
    fi
  done
}

rewrite_pins() {
  local scan_root=${IMAGE_SCAN_ROOT:-$root}
  local line rest old new old_dig new_dig file tmp
  local -a files=() grep_paths=()
  [ -d "$scan_root/modules/workloads" ] && grep_paths+=("$scan_root/modules/workloads")
  [ -d "$scan_root/modules/runtime" ] && grep_paths+=("$scan_root/modules/runtime")
  [ -f "$scan_root/modules/platform/runners.nix" ] && grep_paths+=("$scan_root/modules/platform/runners.nix")
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "image-scan: replace "*) ;;
      *)
        continue
        ;;
    esac
    rest=${line#"image-scan: replace "}
    old=${rest%% *}
    new=${rest#* }
    old_dig=${old##*@}
    new_dig=${new##*@}
    if [[ ! $old_dig =~ ^sha256:[a-f0-9]{64}$ ]] || [[ ! $new_dig =~ ^sha256:[a-f0-9]{64}$ ]]; then
      echo "image-scan: refuse to rewrite $old" >&2
      return 1
    fi
    if [ "$old_dig" = "$new_dig" ]; then
      continue
    fi
    if [ "${#grep_paths[@]}" -eq 0 ]; then
      echo "image-scan: digest not in tree $old_dig" >&2
      return 1
    fi
    files=()
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      files+=("$file")
    done < <(grep -R -l -F -- "$old_dig" "${grep_paths[@]}" || true)
    if [ "${#files[@]}" -eq 0 ]; then
      echo "image-scan: digest not in tree $old_dig" >&2
      return 1
    fi
    for file in "${files[@]}"; do
      tmp=$(mktemp)
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "${line//"$old_dig"/"$new_dig"}"
      done < "$file" > "$tmp"
      mv "$tmp" "$file"
    done
    echo "image-scan: rewrote $old_dig"
  done
}

check_clock() {
  local file failed=0 line sev cve discovered ref extra today_s disc_s age_days
  file=$unfixed_file
  if [ ! -f "$file" ]; then
    echo "image-scan: missing unfixed list $file" >&2
    return 1
  fi
  today_s=$(ymd_days "$(date -u +%Y-%m-%d)")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "" | \#*) continue ;;
    esac
    sev=""
    cve=""
    discovered=""
    ref=""
    extra=""
    read -r sev cve discovered ref extra <<<"$line"
    if [ -z "$sev" ] || [ -z "$cve" ] || [ -z "$discovered" ] || [ -z "$ref" ] || [ -n "$extra" ]; then
      echo "image-scan: bad clock line: $line" >&2
      failed=$((failed + 1))
      continue
    fi
    case "$sev" in
      critical | high | moderate | low) ;;
      *)
        echo "image-scan: bad severity on clock line: $line" >&2
        failed=$((failed + 1))
        continue
        ;;
    esac
    if ! valid_date "$discovered"; then
      echo "image-scan: bad discovery date on clock line: $line" >&2
      failed=$((failed + 1))
      continue
    fi
    disc_s=$(ymd_days "$discovered")
    if [ "$disc_s" -gt "$today_s" ]; then
      echo "image-scan: discovery date is in the future: $line" >&2
      failed=$((failed + 1))
      continue
    fi
    age_days=$((today_s - disc_s))
    case "$sev" in
      low)
        echo "image-scan: report $sev $cve age=${age_days}d $ref"
        ;;
      moderate)
        if [ "${IMAGE_SCAN_GATE:-moderate}" != moderate ]; then
          echo "image-scan: report $sev $cve age=${age_days}d $ref"
        elif [ "$age_days" -gt "$clock_days" ]; then
          echo "image-scan: expired $sev $cve discovered $discovered age=${age_days}d $ref" >&2
          failed=$((failed + 1))
        else
          echo "image-scan: clock $sev $cve age=${age_days}d $ref"
        fi
        ;;
      critical | high)
        if [ "$age_days" -gt "$clock_days" ]; then
          echo "image-scan: expired $sev $cve discovered $discovered age=${age_days}d $ref" >&2
          failed=$((failed + 1))
        else
          echo "image-scan: clock $sev $cve age=${age_days}d $ref"
        fi
        ;;
    esac
  done <"$file"
  if [ "$failed" -ne 0 ]; then
    echo "image-scan: FAIL: $failed unfixed clock entry(s)" >&2
    return 1
  fi
  echo "image-scan: unfixed clock OK"
}

clock_has() {
  local want_sev=$1 want_cve=$2 want_ref=$3 line sev cve discovered ref extra
  [ -f "$unfixed_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "" | \#*) continue ;;
    esac
    sev=""
    cve=""
    discovered=""
    ref=""
    extra=""
    read -r sev cve discovered ref extra <<<"$line"
    if [ "$sev" = "$want_sev" ] && [ "$cve" = "$want_cve" ] && [ "$ref" = "$want_ref" ] && [ -z "$extra" ]; then
      return 0
    fi
  done <"$unfixed_file"
  return 1
}

apply_matches() {
  local ref=$1 failed=0 line sev state cve sev_l today
  today=$(date -u +%Y-%m-%d)
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    sev=""
    state=""
    cve=""
    extra=""
    read -r sev state cve extra <<<"$line"
    if [ -n "$sev" ] && [ -z "$cve" ] && [[ $state == CVE-* || $state == GHSA-* ]]; then
      cve=$state
      state=unknown
    fi
    if [ -z "$sev" ] || [ -z "$state" ] || [ -z "$cve" ] || [ -n "${extra:-}" ]; then
      echo "image-scan: bad grype match: $line" >&2
      failed=$((failed + 1))
      continue
    fi
    sev_l=$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')
    case "$sev_l" in
      medium) sev_l=moderate ;;
    esac
    case "$sev_l" in
      critical | high) ;;
      moderate)
        if [ "${IMAGE_SCAN_GATE:-moderate}" != moderate ]; then
          echo "image-scan: report $sev_l $cve $state $ref"
          continue
        fi
        ;;
      low | negligible | unknown)
        echo "image-scan: report $sev_l $cve $state $ref"
        continue
        ;;
      *)
        echo "image-scan: bad grype severity: $line" >&2
        failed=$((failed + 1))
        continue
        ;;
    esac
    case "$state" in
      fixed)
        echo "image-scan: fixed $sev_l $cve $ref" >&2
        if [ -n "${IMAGE_SCAN_PROPOSE_FILE:-}" ]; then
          printf '%s %s\n' "$cve" "$ref" >> "$IMAGE_SCAN_PROPOSE_FILE"
        else
          failed=$((failed + 1))
        fi
        ;;
      not-fixed | wont-fix | unknown)
        if clock_has "$sev_l" "$cve" "$ref"; then
          echo "image-scan: listed $sev_l $cve $state $ref"
        else
          echo "image-scan: record $sev_l $cve $today $ref" >&2
          failed=$((failed + 1))
        fi
        ;;
      *)
        echo "image-scan: bad grype fix state: $line" >&2
        failed=$((failed + 1))
        ;;
    esac
  done
  [ "$failed" -eq 0 ]
}

if [ "${1:-}" = "--list" ]; then
  list_refs
  exit 0
fi

if [ "${1:-}" = "--check-clock" ]; then
  check_clock
  exit
fi

if [ "${1:-}" = "--apply-matches" ]; then
  if [ -z "${2:-}" ]; then
    echo "image-scan: --apply-matches needs the image ref" >&2
    exit 1
  fi
  apply_matches "$2"
  exit
fi

if [ "${1:-}" = "--follow-tag" ]; then
  if [ -z "${2:-}" ]; then
    echo "image-scan: --follow-tag needs the image ref" >&2
    exit 1
  fi
  IMAGE_SCAN_PROPOSE_FILE=$(mktemp)
  printf 'CVE-TEST %s\n' "$2" > "$IMAGE_SCAN_PROPOSE_FILE"
  IMAGE_SCAN_TRUST_FOLLOW=1
  follow_rc=0
  follow_one "$2" || follow_rc=$?
  rm -f "$IMAGE_SCAN_PROPOSE_FILE"
  exit "$follow_rc"
fi

if [ "${1:-}" = "--rewrite" ]; then
  rewrite_pins
  exit
fi

if ! command -v grype >/dev/null 2>&1; then
  echo "image-scan: grype is not on PATH (nix develop .#scan)" >&2
  exit 1
fi

if [ -n "${IMAGE_SCAN_SCRATCH:-}" ]; then
  if [ ! -d "$IMAGE_SCAN_SCRATCH" ] || [ ! -w "$IMAGE_SCAN_SCRATCH" ]; then
    echo "image-scan: scratch is not writable: $IMAGE_SCAN_SCRATCH" >&2
    exit 1
  fi
fi

failed=0
follow_unresolved=0
IMAGE_SCAN_PROPOSE_FILE=$(mktemp)
attention_file=$(mktemp)
trap 'rm -f "$IMAGE_SCAN_PROPOSE_FILE" "$attention_file"' EXIT
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  echo "image-scan: $ref"
  if ! matches=$(run_grype "registry:${ref}"); then
    echo "image-scan: grype failed for $ref" >&2
    echo "image-scan: blocked scan-failed $ref"
    printf 'scan-failed %s\n' "$ref" >> "$attention_file"
    failed=$((failed + 1))
    continue
  fi
  if ! printf '%s\n' "$matches" | apply_matches "$ref"; then
    printf 'findings %s\n' "$ref" >> "$attention_file"
    failed=$((failed + 1))
  fi
done < <(list_refs)

follow_proposals

while read -r kind ref; do
  [ "$kind" = "findings" ] || continue
  [ -n "$ref" ] || continue
  if [ -n "${handled_ref[$ref]:-}" ]; then
    continue
  fi
  echo "image-scan: blocked unfixed $ref"
  handled_ref[$ref]=1
done < "$attention_file"

clock_rc=0
check_clock || clock_rc=$?

if [ "$failed" -ne 0 ] || [ "$follow_unresolved" -ne 0 ]; then
  echo "image-scan: FAIL: $failed image(s) have an unlisted or fixed medium or higher CVE" >&2
  exit 1
fi
if [ "$clock_rc" -ne 0 ]; then
  exit 1
fi
echo "image-scan: OK"
