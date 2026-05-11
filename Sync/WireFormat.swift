import Foundation
import Network

let kMagic: UInt32 = 0x53594E43  // "SYNC"

enum FrameType: UInt8 {
    case ping = 2
    case pong = 3
    case audio = 4
}

struct Frame {
    let type: FrameType
    let payload: Data
}

enum WireError: Error { case shortRead, badMagic, badType }

extension Frame {
    static let headerSize = 9  // u32 magic + u8 type + u32 length

    static func encode(type: FrameType, payload: Data) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        var magic = kMagic.littleEndian
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        data.append(type.rawValue)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

struct BinaryWriter {
    var data = Data()

    mutating func writeU8(_ v: UInt8) { data.append(v) }

    mutating func writeU16LE(_ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeU32LE(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeF64LE(_ v: Double) {
        var bits = v.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ ptr: UnsafeRawBufferPointer) {
        data.append(contentsOf: ptr)
    }
}

extension Data {
    func readU16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { ptr in
            UInt16(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func readU32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func readF64LE(at offset: Int) -> Double {
        withUnsafeBytes { ptr in
            let bits = UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            return Double(bitPattern: bits)
        }
    }
}

enum FrameReader {
    static func read(from conn: NWConnection,
                     onFrame: @escaping (Frame) -> Void,
                     onError: @escaping (Error?) -> Void) {
        conn.receive(minimumIncompleteLength: Frame.headerSize,
                     maximumLength: Frame.headerSize) { data, _, isComplete, err in
            if let err = err { onError(err); return }
            guard let data = data, data.count == Frame.headerSize else {
                if isComplete { onError(nil) }
                return
            }
            let magic = data.readU32LE(at: 0)
            guard magic == kMagic else { onError(WireError.badMagic); return }
            let typeRaw = data[data.startIndex + 4]
            guard let type = FrameType(rawValue: typeRaw) else {
                onError(WireError.badType); return
            }
            let len = Int(data.readU32LE(at: 5))
            if len == 0 {
                onFrame(Frame(type: type, payload: Data()))
                read(from: conn, onFrame: onFrame, onError: onError)
                return
            }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { payload, _, isComplete, err in
                if let err = err { onError(err); return }
                guard let payload = payload, payload.count == len else {
                    if isComplete { onError(nil) }
                    return
                }
                onFrame(Frame(type: type, payload: payload))
                read(from: conn, onFrame: onFrame, onError: onError)
            }
        }
    }
}
