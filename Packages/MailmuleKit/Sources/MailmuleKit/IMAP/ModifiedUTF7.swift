import Foundation

/// IMAP "modified UTF-7" (RFC 3501 §5.1.3), used for mailbox names, Gmail labels and, in Mailmule,
/// for keywords so tags like "práca" survive as IMAP atoms.
public enum ModifiedUTF7 {
    public static func encode(_ string: String) -> String {
        var result = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending { bytes += [UInt8(unit >> 8), UInt8(unit & 0xff)] }
            let base64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            result += "&\(base64)-"
            pending = []
        }

        for scalar in string.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return result
    }

    public static func decode(_ string: String) -> String {
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let ch = string[index]
            guard ch == "&", let end = string[index...].firstIndex(of: "-") else {
                result.append(ch)
                index = string.index(after: index)
                continue
            }
            let encoded = string[string.index(after: index)..<end]
            if encoded.isEmpty {
                result += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), data.count % 2 == 0 {
                    let units = stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }
                    result += String(decoding: units, as: UTF16.self)
                } else {
                    result += string[index...end]
                }
            }
            index = string.index(after: end)
        }
        return result
    }

    /// IMAP keyword for a tag: spaces and atom-special characters become `_`, the rest is modified UTF-7.
    public static func keyword(forTag tag: String) -> String {
        let special = CharacterSet(charactersIn: " (){%*\"\\]")
        let safe = tag.unicodeScalars.map { special.contains($0) ? "_" : String($0) }.joined()
        return encode(safe)
    }

    public static func tag(forKeyword keyword: String) -> String {
        decode(keyword).replacingOccurrences(of: "_", with: " ")
    }
}
