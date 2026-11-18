#!/usr/bin/env bash
# Render glowing ripple frames for the Agent Glow orb.
# Usage: frames.sh <rrggbb> <outdir>  (color = wallpaper-derived primary)
set -u
hex="${1:-33b1ff}"
out="${2:-frames}"
mkdir -p "$out"
r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
size=128; cx=64; cy=64
frames=20
for i in $(seq 0 $((frames - 1))); do
  # two ripple rings, half a period apart; expand 24->74, fade + thin out
  draw_args=()
  for k in 0 1; do
    read rad alpha width <<< $(awk -v i=$i -v n=$frames -v k=$k 'BEGIN{f=(i/n)+0.5*k; if(f>=1)f-=1; rad=19+40*f; a=0.9-0.75*f; w=4-2.5*f; if(w<1)w=1; printf "%d %.2f %.1f", rad, a, w}')
    draw_args+=(-stroke "rgba($r,$g,$b,$alpha)" -strokewidth "$width" -fill none \
      -draw "circle $cx,$cy $cx,$((cy + rad))")
  done
  core_alpha=$(awk -v i=$i -v n=$frames 'BEGIN{printf "%.2f", 0.75+0.25*sin(2*3.14159*(i/n))}')
  # Crisp rings only (no blur pass): tiny files, smooth carriage.
  magick -size ${size}x${size} xc:none \
    "${draw_args[@]}" \
    -fill "rgba($r,$g,$b,0.95)" -stroke none \
    -draw "circle $cx,$cy $cx,$((cy + 10))" \
    -fill "rgba(255,255,255,$core_alpha)" -stroke none \
    -draw "circle $cx,$cy $cx,$((cy + 4))" \
    -depth 8 -strip -define png:compression-level=9 \
    "$out/frame-$(printf '%02d' $i).png"
done
# static idle frame: single dim ring
magick -size ${size}x${size} xc:none \
  -stroke "rgba(140,140,150,0.55)" -strokewidth 2 -fill none \
  -draw "circle $cx,$cy $cx,$((cy + 14))" \
  "$out/idle.png"
echo "frames -> $out"
