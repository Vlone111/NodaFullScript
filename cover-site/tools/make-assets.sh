#!/usr/bin/env bash
#
# Generate the synthetic test media served by this site.
#
# Everything here is produced from ffmpeg's built-in sources: no third-party
# footage is downloaded, copied or redistributed. The output is genuinely what
# the site claims it is — deterministic patterns for exercising players,
# packagers and CDNs.
#
# Run once. The result is static files; serving them costs no CPU.

set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-${here}/../media}"
duration="${ASSET_DURATION:-30}"
long_duration="${ASSET_LONG_DURATION:-300}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }

mkdir -p "${out}"

# name|filter|description
CLIPS=(
  "timecode|testsrc2=size=1920x1080:rate=30|Frame counter and colour bars for A/V sync checks"
  "gradient|gradients=size=1920x1080:rate=30:nb_colors=4|Smooth gradients for banding and 10-bit checks"
  "motion|testsrc2=size=1920x1080:rate=60|60 fps high-motion source for encoder stress"
)

# label|width|height|video kbps|audio kbps
RENDITIONS=(
  "360p|640|360|800|96"
  "720p|1280|720|2500|128"
  "1080p|1920|1080|5000|128"
)

encode_mp4() {
  local src_filter="$1" name="$2" w="$3" h="$4" vb="$5" ab="$6" dur="$7" dst="$8"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "${src_filter}" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t "${dur}" \
    -vf "scale=${w}:${h}" \
    -c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p \
    -b:v "${vb}k" -maxrate "${vb}k" -bufsize "$(( vb * 2 ))k" \
    -g 60 -keyint_min 60 -sc_threshold 0 \
    -c:a aac -b:a "${ab}k" -ac 2 \
    -movflags +faststart \
    "${dst}"
}

printf 'Generating into %s\n' "${out}"

for clip in "${CLIPS[@]}"; do
  name="${clip%%|*}"
  rest="${clip#*|}"
  filter="${rest%%|*}"
  mkdir -p "${out}/${name}"

  for r in "${RENDITIONS[@]}"; do
    IFS='|' read -r label w h vb ab <<<"${r}"
    dst="${out}/${name}/${name}-${label}.mp4"
    printf '  %s %s\n' "${name}" "${label}"
    encode_mp4 "${filter}" "${name}" "${w}" "${h}" "${vb}" "${ab}" "${duration}" "${dst}"
  done

  # HLS with fMP4 segments, built by remuxing the renditions already encoded.
  printf '  %s hls\n' "${name}"
  hls="${out}/${name}/hls"
  mkdir -p "${hls}"
  : >"${hls}/master.m3u8"
  {
    printf '#EXTM3U\n#EXT-X-VERSION:7\n'
  } >>"${hls}/master.m3u8"

  for r in "${RENDITIONS[@]}"; do
    IFS='|' read -r label w h vb ab <<<"${r}"
    ffmpeg -nostdin -hide_banner -loglevel error -y \
      -i "${out}/${name}/${name}-${label}.mp4" \
      -c copy -f hls \
      -hls_time 4 -hls_playlist_type vod \
      -hls_segment_type fmp4 \
      -hls_fmp4_init_filename "${label}-init.mp4" \
      -hls_segment_filename "${hls}/${label}-%03d.m4s" \
      "${hls}/${label}.m3u8"
    # Derive CODECS from the encoded file instead of hardcoding a level: an
    # overstated level makes some players refuse a rendition they could play.
    # No `local` here: this runs in the script body, not inside a function.
    prof="$(ffprobe -v error -select_streams v:0 -show_entries stream=profile \
      -of csv=p=0 "${out}/${name}/${name}-${label}.mp4")"
    lvl="$(ffprobe -v error -select_streams v:0 -show_entries stream=level \
      -of csv=p=0 "${out}/${name}/${name}-${label}.mp4")"
    case "${prof}" in
      High)     codec="avc1.6400$(printf '%02x' "${lvl}")" ;;
      Main)     codec="avc1.4d00$(printf '%02x' "${lvl}")" ;;
      Baseline|"Constrained Baseline") codec="avc1.4200$(printf '%02x' "${lvl}")" ;;
      *)        codec="avc1.6400$(printf '%02x' "${lvl}")" ;;
    esac
    printf '#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%dx%d,CODECS="%s,mp4a.40.2"\n%s.m3u8\n' \
      "$(( (vb + ab) * 1000 ))" "${w}" "${h}" "${codec}" "${label}" >>"${hls}/master.m3u8"
  done
done

# One long asset: the sustained-download case that short clips cannot exercise.
printf '  sustained 1080p %ss\n' "${long_duration}"
mkdir -p "${out}/sustained"
encode_mp4 "testsrc2=size=1920x1080:rate=30" sustained 1920 1080 5000 128 \
  "${long_duration}" "${out}/sustained/sustained-1080p.mp4"

# Checksums, so anyone can verify a transfer completed intact.
( cd "${out}" && find . -type f \( -name '*.mp4' -o -name '*.m4s' \) -print0 \
    | sort -z | xargs -0 sha256sum >SHA256SUMS )

printf '\nDone. %s files, %s total.\n' \
  "$(find "${out}" -type f | wc -l)" \
  "$(du -sh "${out}" | cut -f1)"
