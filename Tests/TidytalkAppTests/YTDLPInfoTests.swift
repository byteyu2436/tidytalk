import Testing
@testable import TidytalkApp

/// 下载开始前先读到的视频信息（`--print before_dl`），用来先显示标题和封面。
@Suite struct YTDLPInfoTests {
    @Test func readsTitleUploaderAndDuration() {
        let info = YTDLP.info(in: YTDLP.infoPrefix + "用 SwiftUI 做一个菜单栏应用\tTidytalk\t754")
        #expect(info == YTDLP.Info(title: "用 SwiftUI 做一个菜单栏应用", uploader: "Tidytalk", duration: 754))
    }

    @Test func missingFieldsAreNA() {
        let info = YTDLP.info(in: YTDLP.infoPrefix + "Live stream\tNA\tNA")
        #expect(info == YTDLP.Info(title: "Live stream", uploader: nil, duration: nil))
    }

    @Test func tabsInTheTitleAreKept() {
        let info = YTDLP.info(in: YTDLP.infoPrefix + "A\tB\tuploader\t12.5")
        #expect(info?.title == "A\tB")
        #expect(info?.uploader == "uploader")
        #expect(info?.duration == 12.5)
    }

    @Test func otherLinesAreIgnored() {
        #expect(YTDLP.info(in: "[youtube] H3KnMyojEQU: Downloading webpage") == nil)
        #expect(YTDLP.info(in: "用 SwiftUI 做一个菜单栏应用") == nil)
        #expect(YTDLP.info(in: YTDLP.infoPrefix + "NA\tNA\tNA") == nil)
    }
}
