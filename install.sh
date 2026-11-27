#!/bin/sh
# MPV Translate Subtitles — installer
#
# Usage:
#   ./install.sh                    # install latest tagged release
#   ./install.sh --ref v0.3         # install a specific tag
#   curl -fsSL <raw-url>/install.sh | sh
#   MPV_TRANSLATE_SUBTITLES_REF=v0.3 sh -c 'curl -fsSL <raw-url>/install.sh | sh'
#
# Options:
#   --ref <tag>        tag to install (default: latest tag; minimum: v0.2,
#                      the first tag with the libretranslate backend)
#
# Environment:
#   MPV_TRANSLATE_SUBTITLES_REF     same as --ref
#   MPV_TRANSLATE_SUBTITLES_CONFIG  config dir (default: ~/.config/mpv)
#   MPV_TRANSLATE_NONINTERACTIVE=1  skip prompts (write defaults)
#   MPV_TRANSLATE_SKIP_MENU=1       skip the in-player menu step
#
# Non-destructive: only writes to the config dir, never system dirs.
# A menu.conf backup is kept at menu.conf.bak.

set -eu

REPO="kikoninja/mpv-translate-subtitles"
MIN_SUPPORTED="v0.2"
DEFAULT_REF="v0.4"

# ---- arg parsing -----------------------------------------------------------
REF="${MPV_TRANSLATE_SUBTITLES_REF:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --ref=*) REF="${1#--ref=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# *//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---- helpers ---------------------------------------------------------------
die() { echo "install: error: $*" >&2; exit 1; }
info() { echo "install: $*"; }

semver_ge() {
    # $1 >= $2  for tags like v0.2 or v0.2.1
    a=$(echo "$1" | sed 's/^v//'); b=$(echo "$2" | sed 's/^v//')
    IFS=. read -r am am2 am3 <<EOF
$a
EOF
    IFS=. read -r bm bm2 bm3 <<EOF
$b
EOF
    am=${am:-0}; am2=${am2:-0}; am3=${am3:-0}
    bm=${bm:-0}; bm2=${bm2:-0}; bm3=${bm3:-0}
    [ "$am" -gt "$bm" ] && return 0
    [ "$am" -eq "$bm" ] && [ "$am2" -gt "$bm2" ] && return 0
    [ "$am" -eq "$bm" ] && [ "$am2" -eq "$bm2" ] && [ "$am3" -ge "$bm3" ] && return 0
    return 1
}

# ---- resolve ref -----------------------------------------------------------
if [ -z "$REF" ]; then
    if command -v curl >/dev/null 2>&1; then
        REF=$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" 2>/dev/null \
            | grep '"name"' | sed -E 's/.*"name": *"([^"]+)".*/\1/' \
            | sort -t. -k2 -n -k1 -n -k3 -n | tail -1) || REF=""
    fi
    REF="${REF:-$DEFAULT_REF}"
fi

# sort above is best-effort; enforce the floor explicitly
semver_ge "$REF" "$MIN_SUPPORTED" || die "ref '$REF' is older than the minimum supported version ($MIN_SUPPORTED, first tag with the libretranslate backend)"

# ---- resolve source tree ---------------------------------------------------
SRC_DIR=""
if [ -f scripts/translate-subtitles/main.lua ]; then
    # local mode: run from a checkout
    SRC_DIR="$PWD"
    info "local checkout: $SRC_DIR (not using '$REF'; the checked-out tree is installed as-is)"
else
    command -v curl >/dev/null 2>&1 || die "curl is required to download the release"
    command -v tar >/dev/null 2>&1 || die "tar is required to unpack the release"
    info "downloading $REF from $REPO"
    SRC_DIR=$(mktemp -d)
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/$REF.tar.gz" -o "$SRC_DIR/pkg.tar.gz" \
        || die "failed to download tag $REF"
    tar -xzf "$SRC_DIR/pkg.tar.gz" -C "$SRC_DIR" --strip-components=1 \
        || die "failed to unpack tag $REF"
fi

# ---- config dir ------------------------------------------------------------
CONFIG_DIR="${MPV_TRANSLATE_SUBTITLES_CONFIG:-$HOME/.config/mpv}"
OPTS_DIR="$CONFIG_DIR/script-opts"
MENU_CONF="$CONFIG_DIR/menu.conf"
mkdir -p "$OPTS_DIR"

# --- resolve layout: new (dir package) vs flat (.lua) -----------------------
SCRIPT_NAME=""
INSTALLED_DIR=""
FLAT=0
if [ -d "$SRC_DIR/scripts/translate-subtitles" ]; then
    SCRIPT_NAME="translate-subtitles"
    INSTALLED_DIR="$CONFIG_DIR/scripts/translate-subtitles"
elif ls "$SRC_DIR"/scripts/*.lua >/dev/null 2>&1; then
    FLAT=1
    SCRIPT_NAME=$(basename "$SRC_DIR"/scripts/*.lua .lua)
    INSTALLED_DIR="$CONFIG_DIR/scripts/$SCRIPT_NAME.lua"
else
    die "no scripts found under $SRC_DIR/scripts"
fi

info "installing scripts to $INSTALLED_DIR"
if [ "$FLAT" -eq 1 ]; then
    mkdir -p "$CONFIG_DIR/scripts"
    cp "$SRC_DIR"/scripts/*.lua "$INSTALLED_DIR"
else
    mkdir -p "$INSTALLED_DIR"
    cp -r "$SRC_DIR/scripts/translate-subtitles/." "$INSTALLED_DIR/"
fi

# --- config name follows the script name (older versions used a different one) --
CONF="$OPTS_DIR/$SCRIPT_NAME.conf"
HAS_FONT=0
if grep -r -q 'font_size' "$CONFIG_DIR/scripts/" 2>/dev/null; then
    HAS_FONT=1
fi
MENU_SUPPORTED=0
if grep -r -q "'toggle-translate'" "$CONFIG_DIR/scripts/" 2>/dev/null; then
    MENU_SUPPORTED=1
fi

# ---- interactive prompts (TTY only) ----------------------------------------
INTERACTIVE=0
if [ -t 0 ] && [ -z "${MPV_TRANSLATE_NONINTERACTIVE:-}" ]; then
    INTERACTIVE=1
fi

BACKEND="libretranslate"
LT_URL="https://libretranslate.com/translate"
LT_KEY=""

if [ "$INTERACTIVE" -eq 1 ]; then
    echo
    echo "Install options (press Enter to accept the default):"
    echo "  1) google"
    echo "  2) libretranslate"
    printf 'Backend [2]: '
    read -r ans || ans=""
    case "$ans" in
        1|google|Google|GOOGLE) BACKEND="google" ;;
        2|libretranslate|LibreTranslate|LIBRETRANSLATE|"") BACKEND="libretranslate" ;;
        *) echo "unknown choice '$ans'; using libretranslate" >&2; BACKEND="libretranslate" ;;
    esac
    if [ "$BACKEND" = "libretranslate" ]; then
        printf 'LibreTranslate URL [%s]: ' "$LT_URL"
        read -r ans || ans=""
        [ -n "$ans" ] && LT_URL="$ans"
        printf 'LibreTranslate API key [empty = anonymous]: '
        read -r ans || ans=""
        LT_KEY="$ans"
    fi
fi

# ---- write the config file ---------------------------------------------------
if [ -f "$CONF" ]; then
    info "config $CONF already exists — leaving it untouched"
else
    info "writing $CONF"
    {
    echo "# translate-subtitles options (generated by install.sh from $REF)"
    echo "input_lang=en"
    echo "output_lang=id"
    echo "prefetch_seconds=5"
    echo "toggle_key=Ctrl+t"
    echo "curl_command=/usr/bin/curl"
    if [ "$HAS_FONT" -eq 1 ]; then
        echo "font_size=55"
        echo "font_size_step=5"
        echo "increase_font_size_key=Ctrl+up"
        echo "decrease_font_size_key=Ctrl+down"
    fi
    echo ""
    echo "# Which translation backend: \"google\" or \"libretranslate\""
    echo "translation_backend=$BACKEND"
    echo ""
    echo "# LibreTranslate endpoint (only used with translation_backend=libretranslate)"
    echo "libretranslate_url=$LT_URL"
    echo ""
    echo "# Optional LibreTranslate API key. Empty = anonymous usage."
    echo "libretranslate_api_key=$LT_KEY"
    } > "$CONF"
fi

# ---- menu step --------------------------------------------------------------
MENU_HELP="add to $MENU_CONF:
  &Subtitle
  &Translate\tscript-binding translate_subtitles/toggle-translate\tchecked=get(\"user-data/translate-subtitles/enabled\", false)"

if [ -n "${MPV_TRANSLATE_SKIP_MENU:-}" ]; then
    info "skipping menu step (MPV_TRANSLATE_SKIP_MENU=1)"
elif [ "$MENU_SUPPORTED" -eq 0 ]; then
    info "installed version exposes no 'toggle-translate' binding — skipping the context-menu step."
    info "(the in-player menu item requires v0.4+)"
elif ! command -v mpv >/dev/null 2>&1; then
    info "mpv not found on PATH — skipping menu step. To add the menu item manually:"
    echo "  $MENU_HELP"
else
    # idempotency: already injected?
    if [ -f "$MENU_CONF" ] && grep -q 'toggle-translate' "$MENU_CONF"; then
        info "menu.conf already contains the Translate item — nothing to do"
    else
        # should we generate a fresh menu or inject into the existing one?
        GEN=0
        if [ ! -f "$MENU_CONF" ] || ! grep -q '[^[:space:]]' "$MENU_CONF"; then
            GEN=1
        fi

        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' EXIT

        if [ "$GEN" -eq 1 ]; then
            info "generating default menu from mpv via headless throwaway script"
            cat > "$TMP/dump-menu.lua" <<'LUA'
local f = io.open(os.getenv('DUMP_MENU_OUT'), 'w')
if f then
    f:write(mp.get_property('default-menu') or '')
    f:close()
end
mp.quit()
LUA
            DUMP="$TMP/default-menu"
            DUMP_MENU_OUT="$DUMP" timeout 20 mpv --no-config --no-video --vo=null --idle --script="$TMP/dump-menu.lua" >/dev/null 2>&1 || true
            if [ ! -s "$DUMP" ] || ! grep -q '&Subtitle' "$DUMP"; then
                die "could not generate the default menu from mpv (is a display-capable mpv available?). Scripts are installed; to finish manually:\n  $MENU_HELP"
            fi
            cp "$DUMP" "$TMP/menu-final"
        else
            cp "$MENU_CONF" "$TMP/menu-final"
        fi

        # backup once, never overwrite
        if [ -f "$MENU_CONF" ] && [ ! -f "$MENU_CONF.bak" ]; then
            cp "$MENU_CONF" "$MENU_CONF.bak"
            info "backed up existing menu.conf to $MENU_CONF.bak"
        fi

        # inject (awk): add the Translate line after the first &Subtitle header
        # (or append a new section) with a stable indent
        awk '
            /^[[:space:]]*&Subtitle/ && !done {
                print
                print "    &Translate\tscript-binding translate_subtitles/toggle-translate\tchecked=get(\"user-data/translate-subtitles/enabled\", false)"
                done = 1
                next
            }
            { print }
            END {
                if (!done) {
                    print "&Subtitle"
                    print "    &Translate\tscript-binding translate_subtitles/toggle-translate\tchecked=get(\"user-data/translate-subtitles/enabled\", false)"
                }
            }
        ' "$TMP/menu-final" > "$TMP/menu-out"

        if ! grep -q 'toggle-translate' "$TMP/menu-out"; then
            die "menu injection failed (no &Subtitle section matched). Scripts are installed; see:\n  $MENU_HELP"
        fi

        cp "$TMP/menu-out" "$MENU_CONF"
        if [ "$GEN" -eq 1 ]; then
            info "wrote fresh menu.conf at $MENU_CONF"
        else
            info "injected Translate item into $MENU_CONF"
        fi
    fi
fi

info "done. Restart mpv to pick up the installation."
info "Config: $CONF"
