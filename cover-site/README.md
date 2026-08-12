# Bitrail

A public library of deterministic synthetic test video: progressive MP4 and HLS
ladders for exercising players, packagers, caches and CDN configurations.

The site itself is static HTML and one stylesheet — no build step, no
JavaScript, no third-party requests. The media is generated locally by
`tools/make-assets.sh` from ffmpeg's built-in sources, so nothing is downloaded
or redistributed and the content can be CC0.

## Layout

```
index.html              landing page with a native <video> player
docs/index.html         URL layout, range requests, checksums, CI notes
docs/streams.html       catalogue with encoder settings
changelog.html          release history
404.html                not-found page
assets/style.css        the only stylesheet
assets/poster.svg       video poster
tools/make-assets.sh    media generator
media/                  generated output, gitignored
```

## Generating the media

Requires ffmpeg with `libx264` and `aac` — that is the stock build on Debian,
Ubuntu, Homebrew and Alpine.

```sh
./tools/make-assets.sh ./media
```

Defaults produce roughly 400 MB: three patterns × three renditions at 30
seconds, plus one 5-minute 1080p asset. Adjust with:

```sh
ASSET_DURATION=60 ASSET_LONG_DURATION=900 ./tools/make-assets.sh ./media
```

Encoding is the only expensive step and it runs once. Serving the result is
plain static file I/O: no transcoding, no CPU, a few tens of megabytes of RAM
in whatever web server you put in front of it.

## Serving it

Any static server works. Three things matter:

1. **Range requests** must be honoured — the docs tell people to test exactly
   this, so an origin that fakes it is embarrassing.
2. **Do not compress** `/media/**`. It is already compressed; gzip or zstd
   there burns CPU on both ends for nothing.
3. **Correct MIME types** for `.m3u8` (`application/vnd.apple.mpegurl`),
   `.m4s` (`video/iso.segment`) and `.mpd` (`application/dash+xml`). Most
   servers do not know these out of the box.

## Domain placeholder

Canonical links, `robots.txt`, `sitemap.xml` and the example commands in the
docs contain the literal token `__SITE_DOMAIN__`. Replace it before publishing:

```sh
grep -rl __SITE_DOMAIN__ . | xargs sed -i 's/__SITE_DOMAIN__/example.com/g'
```

Deployment tooling may do this automatically.

## Local preview

```sh
python -m http.server 8000
```

Note that `http.server` does not serve `404.html` and does not set the MIME
types above, so HLS playback will not work against it. It is fine for checking
layout only.

## Releases

Tag rather than deploying from the default branch, so a deployment can pin an
exact revision:

```sh
git tag -a site-v1 -m "Initial site"
git push origin site-v1
```

## Licence

Site and generator: MIT, see `LICENSE`. Generated media: CC0 — it is produced
from synthetic sources and contains no third-party material.
