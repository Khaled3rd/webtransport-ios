import Foundation
import CoreMedia

/// Decodes H264 NAL units received from the relay into CMSampleBuffers.
///
/// Protocol framing (per unidirectional stream):
///   Byte 0: 0x01 = keyframe, 0x00 = delta frame
///   Bytes 1…: one or more NAL units in Annex-B format, concatenated
///
/// AVSampleBufferDisplayLayer accepts H264 AVCC CMSampleBuffers directly,
/// so no VTDecompressionSession is needed.
@MainActor
final class H264Decoder {
    var onSampleBuffer: @MainActor (CMSampleBuffer) -> Void = { _ in }

    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var pts: CMTimeValue = 0

    // MARK: - Public

    func decode(payload: Data) {
        guard payload.count > 4 else { return }

        let bytes = Array(payload.dropFirst())  // skip keyframe-flag byte
        let nalRanges = findNalRanges(in: bytes)
        guard !nalRanges.isEmpty else { return }

        print("[decoder] payload=\(payload.count)B header=\(payload.first ?? 0) nals=\(nalRanges.count)")

        var vclNals: [Data] = []

        for range in nalRanges {
            guard !range.isEmpty else { continue }
            let nalData = Data(bytes[range])
            guard !nalData.isEmpty else { continue }

            let nalType = nalData[nalData.startIndex] & 0x1F
            switch nalType {
            case 7:
                print("[decoder] SPS size=\(nalData.count)")
                spsData = nalData
                rebuildFormatDescription()
            case 8:
                print("[decoder] PPS size=\(nalData.count)")
                ppsData = nalData
                rebuildFormatDescription()
            case 1, 5:
                vclNals.append(nalData)
            default:
                break
            }
        }

        if !vclNals.isEmpty {
            submitFrame(vclNals: vclNals)
        }
    }

    // MARK: - Private

    private func findNalRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var starts: [(offset: Int, nalStart: Int)] = []
        var i = 0
        while i < bytes.count {
            if i + 3 < bytes.count,
               bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                starts.append((offset: i, nalStart: i + 4)); i += 4; continue
            }
            if i + 2 < bytes.count,
               bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
                starts.append((offset: i, nalStart: i + 3)); i += 3; continue
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        for idx in 0..<starts.count {
            let s = starts[idx].nalStart
            let e = idx + 1 < starts.count ? starts[idx + 1].offset : bytes.count
            if s < e { ranges.append(s..<e) }
        }
        return ranges
    }

    private func rebuildFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }
        var desc: CMVideoFormatDescription?
        let result = sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) -> OSStatus in
            guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            return pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) -> OSStatus in
                guard let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let ptrs: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return ptrs.withUnsafeBufferPointer { ptrsBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        }
        guard result == noErr, let desc else {
            print("[decoder] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(result)")
            return
        }
        if let existing = formatDescription, CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
            return
        }
        print("[decoder] format description built OK")
        formatDescription = desc
    }

    /// Submit all VCL NALs of one frame as a single AVCC CMSampleBuffer
    /// fed directly to AVSampleBufferDisplayLayer (no VTDecompressionSession).
    private func submitFrame(vclNals: [Data]) {
        guard let fmtDesc = formatDescription else {
            print("[decoder] no fmtDesc, dropping \(vclNals.count) VCL NALs")
            return
        }

        // Build AVCC payload: [4-byte big-endian length][NAL bytes] per slice
        var avcc = Data()
        for nal in vclNals {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }

        // malloc-owned copy so AVSampleBufferDisplayLayer can retain it after return.
        // CMBlockBuffer will free(buf) via kCFAllocatorMalloc when released.
        let count = avcc.count
        guard let buf = malloc(count) else { return }
        avcc.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: count)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: buf,
            blockLength: count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { free(buf); return }

        let presentationTime = CMTime(value: pts, timescale: 30)
        pts += 1

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: fmtDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // Set DisplayImmediately to bypass PTS scheduling in AVSampleBufferDisplayLayer.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        print("[decoder] submitFrame pts=\(pts-1) vclNals=\(vclNals.count)")
        onSampleBuffer(sampleBuffer)
    }
}
