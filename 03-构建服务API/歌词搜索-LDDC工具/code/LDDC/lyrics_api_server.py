from fastapi import FastAPI, Query, HTTPException, Response

from LDDC.core.api.lyrics import search, get_lyricslist, get_lyrics
from LDDC.core.converter import convert2
from LDDC.common.models import Source, SearchType, LyricsFormat

app = FastAPI()


SOURCES = [
    Source.LRCLIB,
    Source.NE,
    Source.QM,
    Source.KG,
]


def build_keyword(title: str, artist: str | None = None, album: str | None = None) -> str:
    parts = [title]
    if artist:
        parts.append(artist)
    if album:
        parts.append(album)
    return " ".join(parts)


@app.get("/lyrics")
def lyrics(
    title: str = Query(..., description="歌曲名"),
    artist: str | None = Query(None, description="歌手"),
    album: str | None = Query(None, description="专辑"),
    source: str | None = Query(None, description="可选：lrclib/ne/qm/kg"),
):
    keyword = build_keyword(title, artist, album)

    if source:
        source_map = {
            "lrclib": Source.LRCLIB,
            "ne": Source.NE,
            "netease": Source.NE,
            "qm": Source.QM,
            "qq": Source.QM,
            "kg": Source.KG,
            "kugou": Source.KG,
        }
        sources = [source_map[source.lower()]]
    else:
        sources = SOURCES

    last_error = None

    for src in sources:
        try:
            results = search(src, keyword, SearchType.SONG, page=1)

            if not results:
                continue

            song = results[0]

            lyric_infos = get_lyricslist(song)

            if not lyric_infos:
                continue

            lyric_info = lyric_infos[0]
            lyrics_obj = get_lyrics(lyric_info)

            lrc_text = convert2(
                lyrics_obj,
                langs=["orig"],
                lyrics_format=LyricsFormat.LINEBYLINELRC,
                offset=0,
            )

            if lrc_text and lrc_text.strip():
                return Response(
                    content=lrc_text,
                    media_type="text/plain; charset=utf-8",
                )

        except Exception as e:
            last_error = str(e)
            continue

    raise HTTPException(
        status_code=404,
        detail={
            "message": "没有找到歌词",
            "title": title,
            "artist": artist,
            "last_error": last_error,
        },
    )


@app.get("/")
def index():
    return {
        "usage": "/lyrics?title=晴天&artist=周杰伦",
        "source": "optional: lrclib / ne / qm / kg",
    }