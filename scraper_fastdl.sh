#!/usr/bin/env bash
set -uo pipefail
BASE_URL="https://main.fastdl.me/maps"
TEMP_DIR="${MAPS_DIR}/.tmp_downloads"
INDEX_CACHE="${HOME}/.fastdl_index_cache"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
MAPS_DIR="${MAPS_DIR:-$(find "${HOME}" -maxdepth 6 -type d -path "*/cstrike/maps" -print -quit)}"
if [[ -z "$MAPS_DIR" ]]; then err "Could not find a cstrike/maps directory under ${HOME}. Set MAPS_DIR manually."; exit 1; fi
for cmd in curl bzip2; do
    command -v "$cmd" &>/dev/null || { err "Required tool not found: $cmd"; exit 1; }
done
mkdir -p "${MAPS_DIR}" "${TEMP_DIR}"
[[ "${1:-}" == "--clear-cache" ]] && rm -f "$INDEX_CACHE" && log "Cache cleared." && exit 0
fetch_index() {
    if [[ -f "$INDEX_CACHE" ]]; then
        log "Using cached map index..."
        MAP_LIST=$(cat "$INDEX_CACHE")
        return
    fi
    log "Fetching map index (first time only)..."
    HTML=$(curl -fsSL "${BASE_URL}/")
    MAP_LIST=$(echo "$HTML" | \
        grep -oP '<tr><td><a href="#">\K[^<]+</a></td><td>[a-f0-9]{40}' | \
        sed 's|</a></td><td>| |' | \
        awk '{print $1 " " $2}')
    if [[ -z "$MAP_LIST" ]]; then
        err "No maps found — site layout may have changed."
        exit 1
    fi
    echo "$MAP_LIST" > "$INDEX_CACHE"
    ok "Index cached to ${INDEX_CACHE}"
}
download_map() {
    local MAP_NAME="$1"
    local SHA1="$2"
    local DOWNLOAD_URL="https://main.fastdl.me/h2/${SHA1}/${MAP_NAME}.bsp.bz2"
    local BSP_PATH="${MAPS_DIR}/${MAP_NAME}.bsp"
    local BZ2_PATH="${TEMP_DIR}/${MAP_NAME}.bsp.bz2"
    if [[ -f "${BSP_PATH}" ]]; then
        ok "SKIP  ${MAP_NAME}.bsp (already exists)"
        return 0
    fi
    echo -ne "${CYAN}[DL]${NC}   ${MAP_NAME}.bsp.bz2 ... "
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${BZ2_PATH}" "${DOWNLOAD_URL}"; then
        echo; err "Failed to download ${MAP_NAME}"; return 1
    fi
    if ! file "${BZ2_PATH}" | grep -q 'bzip2'; then
        echo; err "Not a valid bzip2 file: ${BZ2_PATH}"; rm -f "${BZ2_PATH}"; return 1
    fi
    echo -ne "extracting ... "
    if bzip2 -dk "${BZ2_PATH}" 2>/dev/null; then
        mv -f "${TEMP_DIR}/${MAP_NAME}.bsp" "${BSP_PATH}"
        rm -f "${BZ2_PATH}"
        echo -e "${GREEN}done${NC}"
        return 0
    else
        echo; err "Extraction failed"; rm -f "${BZ2_PATH}"; return 1
    fi
}
shuffle_lines() {
    awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort -n | cut -f2-
}
print_summary() {
    echo
    echo "────────────────────────────────"
    echo -e " ${GREEN}Downloaded : ${1}${NC}"
    echo -e " ${YELLOW}Skipped    : ${2}${NC}"
    echo -e " ${RED}Failed     : ${3}${NC}"
    echo "────────────────────────────────"
}
run_download_loop() {
    local LIST="$1"
    local SUCCESS=0 SKIP=0 FAIL=0
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        local MAP_NAME SHA1
        MAP_NAME=$(echo "$LINE" | awk '{print $1}')
        SHA1=$(echo "$LINE" | awk '{print $2}')
        if download_map "$MAP_NAME" "$SHA1"; then
            (( SUCCESS++ )) || true
        else
            (( FAIL++ )) || true
        fi
    done <<< "$LIST"
    print_summary "$SUCCESS" "$SKIP" "$FAIL"
}
mode_bulk() {
    echo -e "\n${BOLD}Enter map prefix (e.g. bhop_, surf_, kz_):${NC}"
    read -rp "> " PREFIX
    PREFIX="${PREFIX%_}_"
    echo -e "\n${BOLD}How many maps? (0 = all):${NC}"
    read -rp "> " MAX
    [[ ! "$MAX" =~ ^[0-9]+$ ]] && MAX=0
    echo -e "\n${BOLD}Download order:${NC}"
    echo "  1) sequential (first N in index)"
    echo "  2) random (random N from prefix)"
    read -rp "> " ORDER_CHOICE
    MATCHED=$(echo "$MAP_LIST" | awk -v p="^${PREFIX}" '$1 ~ p {print $1 " " $2}')
    if [[ -z "$MATCHED" ]]; then
        warn "No maps found with prefix '${PREFIX}'"
        return
    fi
    case "$ORDER_CHOICE" in
        2)
            log "Shuffling map list..."
            MATCHED=$(echo "$MATCHED" | shuffle_lines)
            ;;
        *)
            ;;
    esac
    [[ "$MAX" -gt 0 ]] && MATCHED=$(echo "$MATCHED" | head -n "$MAX")
    TOTAL=$(echo "$MATCHED" | wc -l | tr -d ' ')
    if [[ "$ORDER_CHOICE" == "2" ]]; then
        log "Randomly selected ${TOTAL} map(s) with prefix '${PREFIX}'"
    else
        log "Found ${TOTAL} map(s) with prefix '${PREFIX}'"
    fi
    run_download_loop "$MATCHED"
}
mode_single() {
    echo -e "\n${BOLD}Search for map name:${NC}"
    read -rp "> " QUERY
    RESULTS=$(echo "$MAP_LIST" | awk -v q="${QUERY}" 'tolower($1) ~ tolower(q) {print $1 " " $2}')
    if [[ -z "$RESULTS" ]]; then
        warn "No maps found matching '${QUERY}'"
        return
    fi
    COUNT=$(echo "$RESULTS" | wc -l | tr -d ' ')
    if [[ "$COUNT" -eq 1 ]]; then
        MAP_NAME=$(echo "$RESULTS" | awk '{print $1}')
        SHA1=$(echo "$RESULTS" | awk '{print $2}')
        log "Found: ${MAP_NAME}"
        download_map "$MAP_NAME" "$SHA1"
    else
        echo -e "\n${BOLD}Multiple matches found:${NC}"
        i=1
        while IFS= read -r LINE; do
            echo "  ${i}) $(echo "$LINE" | awk '{print $1}')"
            (( i++ ))
        done <<< "$RESULTS"
        echo -e "\n${BOLD}Pick a number (or 0 to cancel):${NC}"
        read -rp "> " PICK
        [[ "$PICK" -eq 0 ]] && return
        SELECTED=$(echo "$RESULTS" | sed -n "${PICK}p")
        MAP_NAME=$(echo "$SELECTED" | awk '{print $1}')
        SHA1=$(echo "$SELECTED" | awk '{print $2}')
        download_map "$MAP_NAME" "$SHA1"
    fi
}
mode_list() {
    echo -e "\n${BOLD}Enter map names separated by commas:${NC}"
    echo -e "${CYAN}(e.g. surf_mesa, bhop_arcane_v2, kz_longjumps2)${NC}"
    read -rp "> " RAW_INPUT
    IFS=',' read -ra RAW_MAPS <<< "$RAW_INPUT"
    MAPS=()
    for m in "${RAW_MAPS[@]}"; do
        name=$(echo "$m" | tr -d '[:space:]')
        [[ -n "$name" ]] && MAPS+=("$name")
    done
    if [[ "${#MAPS[@]}" -eq 0 ]]; then
        warn "No map names provided."
        return
    fi
    log "Looking up ${#MAPS[@]} map(s)..."
    SUCCESS=0; SKIP=0; FAIL=0
    for MAP_NAME in "${MAPS[@]}"; do
        MATCH=$(echo "$MAP_LIST" | awk -v n="^${MAP_NAME}$" 'tolower($1) ~ tolower(n) {print $1 " " $2; exit}')
        if [[ -z "$MATCH" ]]; then
            warn "Not found in index: ${MAP_NAME}"
            (( FAIL++ )) || true
            continue
        fi
        SHA1=$(echo "$MATCH" | awk '{print $2}')
        if download_map "$MAP_NAME" "$SHA1"; then
            (( SUCCESS++ )) || true
        else
            (( FAIL++ )) || true
        fi
    done
    print_summary "$SUCCESS" "$SKIP" "$FAIL"
}
mode_keyword() {
    echo -e "\n${BOLD}Enter keyword (matches anywhere in map name, blank = all maps):${NC}"
    read -rp "> " KEYWORD
    if [[ -z "$KEYWORD" ]]; then
        MATCHED="$MAP_LIST"
    else
        MATCHED=$(echo "$MAP_LIST" | awk -v k="${KEYWORD}" 'tolower($1) ~ tolower(k) {print $1 " " $2}')
    fi
    if [[ -z "$MATCHED" ]]; then
        warn "No maps found matching '${KEYWORD}'"
        return
    fi
    TOTAL=$(echo "$MATCHED" | wc -l | tr -d ' ')
    log "Found ${TOTAL} map(s) matching '${KEYWORD:-<all>}'"
    echo -e "\n${BOLD}Enter range to download, e.g. 1-20 (blank = all ${TOTAL}):${NC}"
    read -rp "> " RANGE
    if [[ -n "$RANGE" ]]; then
        if [[ "$RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
            START="${RANGE%-*}"
            END="${RANGE#*-}"
            MATCHED=$(echo "$MATCHED" | sed -n "${START},${END}p")
            NEW_TOTAL=$(echo "$MATCHED" | wc -l | tr -d ' ')
            log "Selected range ${START}-${END} (${NEW_TOTAL} map(s))"
        else
            warn "Invalid range format, ignoring — expected e.g. 5-15"
        fi
    fi
    if [[ -z "$MATCHED" ]]; then
        warn "Range selected zero maps."
        return
    fi
    run_download_loop "$MATCHED"
}
[[ "${1:-}" == "--clear-cache" ]] && rm -f "$INDEX_CACHE" && log "Cache cleared." && exit 0
fetch_index
echo -e "\n${BOLD}what do you want, chud${NC}"
echo "  1) download maps by prefix"
echo "  2) search and download a specific map"
echo "  3) download a list of maps"
echo "  4) keyword search / range download"
echo "  5) clear map index cache"
read -rp "> " CHOICE
case "$CHOICE" in
    1) mode_bulk ;;
    2) mode_single ;;
    3) mode_list ;;
    4) mode_keyword ;;
    5) rm -f "$INDEX_CACHE" && log "Cache cleared." ;;
    *) err "invalid choice"; exit 1 ;;
esac
rmdir "${TEMP_DIR}" 2>/dev/null || true
