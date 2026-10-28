import CoreGraphics
import Testing
@testable import TidytalkApp

/// 属性标签一行放不下时换行，不截断（英文界面的会议详情、转写详情）。
@Suite struct ChipRowTests {
    let chip = CGSize(width: 100, height: 24)

    @Test func chipsThatFitStayOnOneRow() {
        let frames = ChipRow.frames(for: [chip, chip, chip], width: 320, spacing: 6)
        #expect(frames.map(\.minX) == [0, 106, 212])
        #expect(frames.allSatisfy { $0.minY == 0 && $0.width == 100 })
    }

    @Test func chipThatDoesNotFitMovesToTheNextRow() {
        let frames = ChipRow.frames(for: [chip, chip, chip], width: 300, spacing: 6)
        #expect(frames[2] == CGRect(x: 0, y: 30, width: 100, height: 24))
        // 换行后不压缩前面的标签
        #expect(frames[0].width == 100 && frames[1].width == 100)
    }

    @Test func chipWiderThanTheRowIsClampedToTheRow() {
        let frames = ChipRow.frames(for: [chip, CGSize(width: 500, height: 24)], width: 300, spacing: 6)
        #expect(frames[1] == CGRect(x: 0, y: 30, width: 300, height: 24))
    }
}
