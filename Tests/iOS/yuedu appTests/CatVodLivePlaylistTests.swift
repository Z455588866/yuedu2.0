import Foundation
import Testing
@testable import yuedu_app

/// 直播列表解析：TVBox 的 M3U / TXT 两种写法。
@Suite("CatVod live playlist", .serialized)
struct CatVodLivePlaylistTests {

    private let source = CatVodLiveSource(name: "默认", url: "https://example.com/tv.m3u")

    @Test("TXT：分组行切组，频道行带地址")
    func parsesTXT() {
        let text = """
        央视频道,#genre#
        CCTV-1,http://a.example/cctv1.m3u8
        CCTV-2,http://a.example/cctv2.m3u8
        卫视频道,#genre#
        湖南卫视,http://a.example/hunan.m3u8
        """
        let channels = CatVodLivePlaylist.parse(text, source: source)
        #expect(channels.count == 3)
        #expect(channels[0].name == "CCTV-1")
        #expect(channels[0].group == "央视频道")
        #expect(channels[2].group == "卫视频道")
        #expect(channels[2].address?.absoluteString == "http://a.example/hunan.m3u8")
    }

    @Test("TXT：# 分隔的多线路每个都留下，注释行忽略")
    func parsesMultipleURLs() {
        let text = """
        # 这是注释
        CCTV-1,http://a.example/1.m3u8#http://b.example/1.m3u8
        """
        let channels = CatVodLivePlaylist.parse(text, source: source)
        #expect(channels.count == 1)
        #expect(channels[0].urls.count == 2)
    }

    @Test("M3U：group-title 与 tvg-logo，逗号后是频道名")
    func parsesM3U() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-name="CCTV1" tvg-logo="http://logo/1.png" group-title="央视",CCTV-1
        http://a.example/1.m3u8
        #EXTINF:-1 group-title="卫视",湖南卫视
        http://a.example/hunan.m3u8
        """
        let channels = CatVodLivePlaylist.parse(text, source: source)
        #expect(channels.count == 2)
        #expect(channels[0].name == "CCTV-1")
        #expect(channels[0].group == "央视")
        #expect(channels[0].logo == "http://logo/1.png")
        #expect(channels[1].group == "卫视")
    }

    @Test("M3U：#EXTVLCOPT 的 UA 与 Referer 变成请求头")
    func readsVLCOptions() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="央视",CCTV-1
        #EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
        #EXTVLCOPT:http-referrer=http://ref.example/
        http://a.example/1.m3u8
        """
        let channels = CatVodLivePlaylist.parse(text, source: source)
        #expect(channels.count == 1)
        #expect(channels[0].headers["User-Agent"] == "Mozilla/5.0 Test")
        #expect(channels[0].headers["Referer"] == "http://ref.example/")
    }

    @Test("同名频道合并线路，顺序不变")
    func mergesDuplicateNames() {
        let text = """
        央视,#genre#
        CCTV-1,http://a.example/1.m3u8
        CCTV-2,http://a.example/2.m3u8
        CCTV-1,http://b.example/1.m3u8
        """
        let channels = CatVodLivePlaylist.merge(CatVodLivePlaylist.parse(text, source: source))
        #expect(channels.count == 2)
        #expect(channels[0].name == "CCTV-1")
        #expect(channels[0].urls.count == 2)
    }

    @Test("空列表与乱码行不产生频道")
    func ignoresNoise() {
        #expect(CatVodLivePlaylist.parse("", source: source).isEmpty)
        #expect(CatVodLivePlaylist.parse("这是一行说明\n没有逗号", source: source).isEmpty)
    }
}
