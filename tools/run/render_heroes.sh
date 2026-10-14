#!/usr/bin/env bash
# Hero reference renders (inputs for generated splash art, portraits and icons): every hero's 3D model rendered by the
# game itself on a transparent background, full body and bust, plus the game's own painted hero art as a bonus.
#
# Output (work/ is never committed):
#   work/art/refs/<Hero>_full.png, <Hero>_bust.png   2048x2048 RGBA (sRGB, straight alpha), <Hero> = DT_Heroes row
#   work/art/refs/sheet.jpg                           contact sheet (all heroes on grey, full + bust)
#   work/art/game/<Texture>.png                       official painted art from the pak: /Game/UI/Textures/Hero3DRenders
#                                                     (<Hero>3DFace, <Hero>_3DUpperBody, incl. Warlock, Scythe, Sniper,
#                                                     WaterBlade, PriestHeroSelectBannerImage) and HeroSelect<Name>
#   work/art/raw/render.log, post.log                 what was rendered (source asset, mesh, anim, framing), notes
# Method:
#   One GPU-rendered headless client (tools/run/headless.sh: private network namespace, own backend data) logs in to
#   the main menu (LE_MainMenu_Map); FangsCtl runs tools/run/render_heroes.lua in the game:
#   - each hero is built the way the menus build their preview: DA_<Hero>_Preview (DA_PreviewHeroCollection) gives
#     the default skin's skeletal mesh and materials and the preview anim BP (menu idle pose); companions
#     (AdditionalSkinDetails: Zoey's Boo) as extra meshes; a hero without a preview asset (BladeMaster) from its
#     character Blueprint's mesh. A SkeletalMeshActor far above the menu map, LOD 0, texture mips forced resident.
#     Where the preview pose is unusable an animation sequence is played instead (anim_override in the .lua: Sniper's
#     and Scythe's in-game idles, a twin-sword idle for BladeMaster, Boo's idle).
#   - the hero materials are unlit toon shaders (M_Character_PBRLite_Global: painted light and shadow textures)
#     whose light/shadow split follows only the direction of the atmosphere sun light: a movable DirectionalLight of
#     ours is the sun (35 degrees to the side of the camera, 40 degrees up), the map's light is switched off.
#   - an own SceneCapture2D renders only the hero (show-only list), CaptureSource SceneColorHDR into an RGBA16f
#     target: linear colour plus inverse opacity in alpha (the alpha the game's BP_CaptureHero uses). No tonemapper
#     or exposure: the capture's auto exposure crushes FinalColor and can't be overridden, so the colours are the
#     materials' own (flat, like the textures).
#   - framing: camera 30 degrees to the hero's left of the body's facing in the pose (measured across hips and
#     shoulders: the preview poses are turned up to 70 degrees), level, 25 degree FOV. A 128 px probe capture, read back pixel by
#     pixel, finds the silhouette; the full body (silhouette + 3%) and the bust (head and shoulders: half the head
#     joint's height, at least 1.3x the silhouette width at the head, top of the head included) are windows of that
#     camera, each rendered as 3x3 tiles of 2048 px (off-axis projection matrices) = 6144 px, exported as EXR.
#     2048 px tiles keep GPU memory low; other tests may share the GPU.
#   The Python below stitches the tiles, downsamples (about 3x supersampling = anti-aliasing), un-premultiplies,
#   rolls off emissive highlights, encodes sRGB and writes the PNGs and the sheet.
# Usage: [HEROES="Warlock Priest"] [SIZE=2048] [GAME_ART=0] [KEEP_RAW=1] [CLIENT_DIR=clients/<build>] tools/run/render_heroes.sh
#   About 45 s login, then 8-15 s per hero; the session ends as soon as the client is done (DURATION caps it).
#   Own backend data and game servers; never touches work/hosts, backend/data or a local play session.
#   Lua tuning knobs (camera/sun angles, tiles, framing): DEFAULTS in render_heroes.lua; LUA_OPTS="key = value, ..."
#   adds/overrides them, e.g. LUA_OPTS='cam_az = -30'.
set -u
cd "$(dirname "$0")/../.."
REPO=$PWD
R=${RUN:-art-render}
ALL="Berserker ShieldGirl Lancer Gunslinger Backstab FireMage IceMage LightningArcher DemonGirl WoodenSword BookMage
 Sidekick BattleMonk CatSupp BigBoi Warlock Priest WaterBlade Scythe Sniper BladeMaster"
HEROES=${HEROES:-$ALL}
OUT=$REPO/work/art
RAW=$OUT/raw
rm -rf "$RAW" work/run/$R-hosts work/run/$R-store.json
mkdir -p "$RAW/game" "$OUT/refs" "$OUT/game"
BIN=work/run/$R/MOBA/Binaries/Win64
A=$BIN/fangsctl_cmd.txt
lua_heroes=$(printf '"%s",' $HEROES)
art=
if [[ ${GAME_ART:-1} == 1 ]]; then
  for t in Astrada3DFace Astrada3DUpperBody Backstab3DFace Backstab3DUpperBody BattleMonk3DFace BattleMonk3DUpperBody \
      BigBoi3DFace BigBoi_3DUpperBody Bookmage3DFace Bookmage3DUpperBody Brutus3DFace Brutus3DUpperBody Ethryn3DFace \
      Ethryn_3DUpperBody Fiorne3DFace Fiorne3DUpperBody Gunslinger3DFace Gunslinger3DUpperBody Kiona3DFace Kiona3DUpperBody \
      PriestHeroSelectBannerImage Rayo3DFace Rayo3DUpperBody Rose3DFace Rose3DUpperBody Rowen3DFace Rowen3DUpperBody \
      Scythe3DFace Scythe_3DUpperBody Sidekick3DFace Sidekick3DUpperBody Sniper3DFace Sniper_3DUpperBody Warlock3DFace \
      Warlock_3DUpperBody WaterBlade3DFace WaterBlade3DUpperBody ZoeyandBoo3DFace ZoeyandBoo_3DUpperBody; do
    art+="\"/Game/UI/Textures/Hero3DRenders/$t.$t\","
  done
  for n in Astrada Belroth Brutus Ethryn Fiorne Ishir Kiona Rayo Rose Rowan Somnia Tufts Wylde Yanari Zoey; do
    art+="\"/Game/HeroSelectRenders/BaseHero3DRenders/HeroSelect$n.HeroSelect$n\","
  done
fi
START="lua dofile(\"Z:$REPO/tools/run/render_heroes.lua\") return FCE_ART.start({ out = \"Z:$RAW\", heroes = { $lua_heroes }, game_art = { $art } ${LUA_OPTS:+, $LUA_OPTS} })"

ours() {   # pids of this run's game client (by working directory)
  for pid in $(pgrep -u "$(id -u)" -f MOBA-Win64-Shipping 2>/dev/null); do
    [[ $(readlink /proc/$pid/cwd 2>/dev/null) == "$REPO/$BIN" ]] && echo "$pid"
  done
}
(
  # wait for the main menu (FangsBoot cleans it up once the login is through)
  for _ in $(seq 1 60); do sleep 5; grep -q 'menu: cleaned up' $BIN/fangsboot.log 2>/dev/null && break; done
  sleep 10
  for _ in 1 2 3 4 5 6; do
    printf '%s\n' "$START" >> $A; sleep 5
    grep -q 'lua ok: started' $BIN/fangsctl.log 2>/dev/null && break
  done
  grep 'lua .*: \(started\|not ready\)' $BIN/fangsctl.log | tail -1 | cut -c21-200
  # wait for the end of the work, or for the client to die
  while ! grep -q 'ALL DONE' "$RAW/render.log" 2>/dev/null; do
    sleep 5
    [[ -z $(ours) ]] && { echo "client gone before ALL DONE"; break; }
  done
  # end the session now: stop the namespace's timer (its 'sleep'), headless.sh then shuts everything down
  pid=$(ours | head -1)
  if [[ -n $pid ]]; then
    ns=$(readlink /proc/$pid/ns/net)
    for p in $(pgrep -u "$(id -u)" -x sleep); do [[ $(readlink /proc/$p/ns/net 2>/dev/null) == "$ns" ]] && kill "$p"; done
  fi
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-900}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=artist -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua error' $BIN/fangsctl.log 2>/dev/null | cut -c21-300
grep -E 'SKIP|ERROR|missing|loaded' "$RAW/render.log" | cut -c10-300

python3 -I - "$RAW" "$OUT" "${SIZE:-2048}" <<'PY' 2>&1 | tee "$RAW/post.log"
"""stitch the EXR tiles from render_heroes.lua into transparent PNGs, convert the game art, draw the contact sheet"""
import glob, json, os, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import OpenImageIO as oiio   # EXR reader (python OpenImageIO bindings)
def read(path): return oiio.ImageBuf(path).get_pixels(oiio.FLOAT)
raw, out, SIZE = sys.argv[1], sys.argv[2], int(sys.argv[3])
refs, game = f'{out}/refs', f'{out}/game'
NAMES = {'Berserker': 'Brutus', 'ShieldGirl': 'Ethryn', 'Lancer': 'Fiorne', 'Gunslinger': 'Wylde', 'Backstab': 'Ishir',
         'FireMage': 'Astrada', 'IceMage': 'Kiona', 'LightningArcher': 'Rayo', 'DemonGirl': 'Rose', 'WoodenSword': 'Rowan',
         'BookMage': 'Somnia', 'Sidekick': 'Tufts', 'BattleMonk': 'Yanari', 'CatSupp': 'Zoey & Boo', 'BigBoi': 'Belroth',
         'Warlock': 'Withergrim (unreleased)', 'Priest': 'Ellis (unreleased)', 'WaterBlade': 'Nuali (unreleased)',
         'Scythe': '(unreleased, no name)', 'Sniper': '(unreleased, no name)', 'BladeMaster': '(unreleased placeholder)'}

def srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)

def shoulder(x, k=0.8):   # emissive parts go above 1: roll off instead of clipping
    return np.where(x > k, k + (1 - k) * (1 - np.exp(-(x - k) / (1 - k))), x)

def stitch(hero, kind, n):
    rows = [np.concatenate([read(f'{raw}/{hero}_{kind}_{j}_{i}.exr') for i in range(n)], 1) for j in range(n)]
    img = np.concatenate(rows, 0)
    a = np.clip(1 - img[..., 3:4], 0, 1)                            # SceneColorHDR alpha = inverse opacity
    return np.concatenate([np.clip(img[..., :3], 0, None), a], -1)  # rendered over black: premultiplied

def crop(img, x0, y0, side):   # square crop, transparent outside
    x0, y0, side = int(round(x0)), int(round(y0)), int(round(side))
    o = np.zeros((side, side, 4), np.float32)
    h, w = img.shape[:2]
    sx0, sy0, sx1, sy1 = max(0, x0), max(0, y0), min(w, x0 + side), min(h, y0 + side)
    if sx1 > sx0 and sy1 > sy0:
        o[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = img[sy0:sy1, sx0:sx1]
    return o

def resize(img, size):   # premultiplied float RGBA, box filter when shrinking (supersampling)
    if img.shape[0] == size:
        return img
    f = Image.BOX if img.shape[0] > size else Image.LANCZOS
    return np.stack([np.asarray(Image.fromarray(np.ascontiguousarray(img[..., c]), 'F').resize((size, size), f)) for c in range(4)], -1)

def save_png(img, path):
    a = np.clip(img[..., 3:4], 0, 1)
    rgb = np.where(a > 1 / 512, img[..., :3] / np.maximum(a, 1e-6), 0)   # un-premultiply
    o = np.concatenate([srgb(shoulder(rgb)), a], -1)
    Image.fromarray((o * 255 + 0.5).astype(np.uint8), 'RGBA').save(path, optimize=True)

meta, heroes, notes = {}, [], {}
for line in open(f'{raw}/render.log', encoding='utf-8', errors='replace'):
    m = re.search(r'META (\{.*\})', line)
    if m:
        d = json.loads(m.group(1)); meta[(d['hero'], d['kind'])] = d
        if d['hero'] not in heroes: heroes.append(d['hero'])
ok = True
for hero in heroes:
    n = notes.setdefault(hero, [])
    try:
        d = meta.get((hero, 'full'))
        if d:
            img = stitch(hero, 'full', d['n'])
            ys, xs = np.nonzero(img[..., 3] > 0.02)
            x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
            H, W = img.shape[:2]
            if d.get('edge') or x0 == 0 or y0 == 0 or x1 == W - 1 or y1 == H - 1:
                n.append('FULL BODY CUT OFF AT THE EDGE')
            side = max(x1 - x0, y1 - y0) * 1.06
            res = min(SIZE, int(side))
            save_png(resize(crop(img, (x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2, side), res), f'{refs}/{hero}_full.png')
            n.append(f'full: figure {x1 - x0}x{y1 - y0} px of {W} -> {res} px; {d["source"]}, head bone {d["headbone"]}')
        d = meta.get((hero, 'bust'))
        if d:   # the bust window was chosen in the game: only downsample
            img = stitch(hero, 'bust', d['n'])
            res = min(SIZE, img.shape[0])
            save_png(resize(img, res), f'{refs}/{hero}_bust.png')
            n.append(f'bust: {img.shape[0]} -> {res} px')
    except Exception as e:   # noqa: BLE001 - keep going with the other heroes
        ok = False; n.append(f'POST ERROR {e!r}')

for p in sorted(glob.glob(f'{raw}/game/*.exr')):   # canvas copies of game textures: straight alpha, linear
    a = read(p)
    rgb = srgb(a[..., :3])
    mode, ch = ('RGB', rgb) if a[..., 3].min() > 0.999 else ('RGBA', np.concatenate([rgb, np.clip(a[..., 3:4], 0, 1)], -1))
    Image.fromarray((ch * 255 + 0.5).astype(np.uint8), mode).save(f'{game}/{os.path.basename(p)[:-4]}.png', optimize=True)
    print('game art:', os.path.basename(p)[:-4], f'{a.shape[1]}x{a.shape[0]}', mode)

order = [h for h in NAMES if h in heroes] + [h for h in heroes if h not in NAMES]
cell, label, cols = 420, 40, 4
sheet = Image.new('RGB', (cols * cell * 2, ((len(order) + cols - 1) // cols) * (cell + label)), (52, 54, 58))
dr = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype('DejaVuSans.ttf', 22)
except OSError:
    font = ImageFont.load_default()
bg = Image.new('RGBA', (cell, cell), (118, 120, 126, 255))
for k, hero in enumerate(order):
    x, y = (k % cols) * cell * 2, (k // cols) * (cell + label)
    for j, kind in enumerate(('full', 'bust')):
        p = f'{refs}/{hero}_{kind}.png'
        if os.path.exists(p):
            im = Image.open(p).convert('RGBA'); im.thumbnail((cell - 8, cell - 8), Image.LANCZOS)
            t = bg.copy(); t.alpha_composite(im, ((cell - im.width) // 2, (cell - im.height) // 2))
            sheet.paste(t.convert('RGB'), (x + j * cell + 4, y + 4))
    dr.text((x + 10, y + cell + 6), f'{hero}  -  {NAMES.get(hero, "")}', fill=(235, 235, 235), font=font)
if order:
    sheet.save(f'{refs}/sheet.jpg', quality=90)
for hero in order:
    print(f'{hero}: ' + '; '.join(notes.get(hero, [])))
print('post: ok' if ok else 'post: errors')
PY
if [[ ${KEEP_RAW:-0} != 1 ]] && grep -q 'post: ok' "$RAW/post.log"; then
  rm -f "$RAW"/*.exr "$RAW"/game/*.exr
fi
ls work/art/refs/*_full.png 2>/dev/null | wc -l | sed 's/$/ heroes rendered (work\/art\/refs)/'
