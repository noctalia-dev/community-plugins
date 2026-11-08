"""Local yt-dlp extractors for Mix detection and watch-page recommendations."""

from collections.abc import Mapping
from importlib import import_module

# This module runs inside yt-dlp, whose Python environment can differ from the editor.
youtube = import_module("yt_dlp.extractor.youtube")
ExtractorError = import_module("yt_dlp.utils").ExtractorError

__all__ = ['YoutubeExplorerMixIE', 'YoutubeExplorerRelatedIE']


def _get_path(value: object, *keys: str) -> object:
    for key in keys:
        if not isinstance(value, Mapping):
            return None
        value = value.get(key)
    return value


class YoutubeExplorerMixIE(youtube.YoutubeTabBaseInfoExtractor):
    IE_NAME = 'youtube-explorer:mix'
    _VALID_URL = r'https://www\.youtube\.com/watch\?v=(?P<id>[A-Za-z0-9_-]{11})&list=RD(?P=id)$'

    def _real_extract(self, url):
        # Keep yt-dlp's normal Mix extraction, but don't resolve its single-video
        # redirect: a missing playlist must not trigger format/player extraction.
        result = youtube.YoutubeTabIE(self._downloader).extract(url)
        if (result.get('_type') in ('url', 'url_transparent')
                and result.get('ie_key') in (None, 'Youtube')
                and result.get('url') == 'https://www.youtube.com/watch?v=' + self._match_id(url)):
            return self.playlist_result([], self._match_id(url))
        return result


class YoutubeExplorerRelatedIE(youtube.YoutubeTabBaseInfoExtractor):
    IE_NAME = 'youtube-explorer:related'
    _VALID_URL = r'ytexplorer-related:(?P<id>[A-Za-z0-9_-]{11})$'

    def _real_extract(self, url):
        video_id = self._match_id(url)
        response = self._extract_response(
            video_id, {'videoId': video_id, 'contentCheckOk': True, 'racyCheckOk': True},
            ep='next', check_get_keys='contents')
        results = _get_path(response, 'contents', 'twoColumnWatchNextResults',
                            'secondaryResults', 'secondaryResults', 'results')
        if not isinstance(results, list):
            raise ExtractorError('Related video response has no recommendation section', expected=True)
        return self.playlist_result(self._related_entries(results), video_id, 'Related videos')

    def _related_entries(self, results):
        # Read only the recommendation section and known wrappers. Recursing over
        # arbitrary JSON can pick up ads, playlists, or the video being watched.
        for item in results:
            if not isinstance(item, dict):
                continue
            renderer = item.get('compactVideoRenderer') or item.get('videoRenderer')
            if isinstance(renderer, dict) and renderer.get('videoId'):
                yield self._extract_video(renderer)
                continue
            model = item.get('lockupViewModel')
            if isinstance(model, dict) and model.get('contentType') == 'LOCKUP_CONTENT_TYPE_VIDEO':
                entry = self._extract_lockup_view_model(model)
                if entry:
                    yield entry
                continue
            section = item.get('itemSectionRenderer')
            if isinstance(section, dict) and isinstance(section.get('contents'), list):
                yield from self._related_entries(section['contents'])
            rich = _get_path(item, 'richItemRenderer', 'content')
            if isinstance(rich, dict):
                yield from self._related_entries([rich])
