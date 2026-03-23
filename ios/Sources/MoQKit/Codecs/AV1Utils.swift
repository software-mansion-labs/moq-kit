#if os(iOS)
    import Foundation

    enum AV1Utils {
        /// Scan an AV1 OBU stream and return the raw bytes (header + body) of the first
        /// Sequence Header OBU (type 1), or nil if none is found.
        static func extractSequenceHeader(from payload: Data) -> Data? {
            var offset = payload.startIndex

            while offset < payload.endIndex {
                let headerStart = offset

                guard offset < payload.endIndex else { return nil }
                let headerByte = payload[offset]
                offset += 1

                let obuType = (headerByte >> 3) & 0xF
                let extensionFlag = (headerByte >> 2) & 0x1
                let hasSizeField = (headerByte >> 1) & 0x1

                // Skip optional extension header byte
                if extensionFlag != 0 {
                    guard offset < payload.endIndex else { return nil }
                    offset += 1
                }

                // Read OBU payload size
                let obuSize: Int
                if hasSizeField != 0 {
                    guard let (size, count) = readLEB128(from: payload, at: offset) else {
                        return nil
                    }
                    obuSize = size
                    offset += count
                } else {
                    // No size field: this OBU extends to the end of the payload
                    obuSize = payload.endIndex - offset
                }

                guard offset + obuSize <= payload.endIndex else { return nil }

                if obuType == 1 {  // OBU_SEQUENCE_HEADER
                    return payload.subdata(in: headerStart ..< offset + obuSize)
                }

                offset += obuSize
            }

            return nil
        }

        // MARK: - Private

        /// Read a LEB128-encoded unsigned integer from `data` starting at `offset`.
        /// Returns `(value, bytesRead)` or nil if the data is malformed or truncated.
        private static func readLEB128(from data: Data, at offset: Int) -> (Int, Int)? {
            var result = 0
            var shift = 0
            var pos = offset

            while pos < data.endIndex {
                let byte = Int(data[pos])
                pos += 1
                result |= (byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return (result, pos - offset)
                }
                shift += 7
                if shift >= 35 { return nil }  // guard against absurdly large values
            }

            return nil  // truncated
        }
    }

#endif
