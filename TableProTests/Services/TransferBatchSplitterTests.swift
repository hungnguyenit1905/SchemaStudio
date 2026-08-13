import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferBatchSplitter")
struct TransferBatchSplitterTests {
    private func splitter(
        maxBytes: Int,
        maxBindParameters: Int = 100_000,
        columnCount: Int = 2
    ) -> TransferBatchSplitter {
        TransferBatchSplitter(
            maxBytes: maxBytes,
            maxBindParameters: maxBindParameters,
            columnCount: columnCount
        )
    }

    private func row(_ byteCount: Int) -> [PluginCellValue] {
        [.text(String(repeating: "a", count: byteCount / 2)), .text(String(repeating: "b", count: byteCount / 2))]
    }

    @Test("a row that fits buffers")
    func rowThatFitsBuffers() {
        var splitter = splitter(maxBytes: 1_000)
        #expect(splitter.append(row(100), estimatedBytes: 100) == .buffered)
        #expect(splitter.bufferedRows == 1)
        #expect(splitter.bufferedBytes == 100)
    }

    @Test("a single oversized row is sent alone")
    func singleOversizedRowSentAlone() {
        var splitter = splitter(maxBytes: 1_000)
        #expect(splitter.append(row(1_500), estimatedBytes: 1_500) == .sendAlone)
        #expect(splitter.bufferedRows == 0)
    }

    @Test("byte ceiling fires before the bind ceiling")
    func byteCeilingFiresBeforeBindCeiling() {
        var splitter = splitter(maxBytes: 1_000, maxBindParameters: 100_000, columnCount: 2)
        #expect(splitter.append(row(400), estimatedBytes: 400) == .buffered)
        #expect(splitter.append(row(400), estimatedBytes: 400) == .buffered)
        #expect(splitter.append(row(400), estimatedBytes: 400) == .flushBefore)
        #expect(splitter.bufferedBytes == 800)
    }

    @Test("bind ceiling fires before the byte ceiling")
    func bindCeilingFiresBeforeByteCeiling() {
        var splitter = splitter(maxBytes: 1_000_000, maxBindParameters: 4, columnCount: 2)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .buffered)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .buffered)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .flushBefore)
        #expect(splitter.bufferedRows == 2)
    }

    @Test("reset empties the buffer for the next append")
    func resetEmptiesBuffer() {
        var splitter = splitter(maxBytes: 1_000, maxBindParameters: 4, columnCount: 2)
        _ = splitter.append(row(10), estimatedBytes: 10)
        _ = splitter.append(row(10), estimatedBytes: 10)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .flushBefore)

        splitter.reset()
        #expect(splitter.bufferedRows == 0)
        #expect(splitter.bufferedBytes == 0)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .buffered)
    }

    @Test("a degenerate column count wider than the bind limit still buffers once")
    func degenerateColumnCountBuffersOnce() {
        var splitter = splitter(maxBytes: 1_000, maxBindParameters: 2, columnCount: 4)
        #expect(splitter.append(row(10), estimatedBytes: 10) == .buffered)
        #expect(splitter.bufferedRows == 1)
    }

    @Test("estimated bytes measures null, text and binary cells")
    func estimatedBytesMeasuresCells() {
        let values: [PluginCellValue] = [.null, .text("é"), .bytes(Data([0x01, 0x02]))]
        #expect(TransferBatchSplitter.estimatedBytes(for: values) == 4 + 2 + 2)
    }
}
