
public struct JSONParser {
    public init() {}

    @inlinable
    public func parse<Bytes: Collection>(bytes: Bytes) throws
        -> JSONValue where Bytes.Element == UInt8 {
        var impl = JSONParserImpl(bytes: bytes)
        return try impl.parse()
    }
}

@usableFromInline struct JSONParserImpl {
    @usableFromInline var reader: DocumentReader
    @usableFromInline var depth: Int = 0

    @inlinable init<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        reader = DocumentReader(bytes: bytes)
    }

    @usableFromInline mutating func parse() throws -> JSONValue {
        let value = try parseValue()
        #if DEBUG
            defer {
                guard self.depth == 0 else {
                    preconditionFailure("Expected to end parsing with a depth of 0")
                }
            }
        #endif

        // handle extra character if top level was number
        if case .number = value {
            guard let extraCharacter = reader.value else {
                return value
            }

            switch extraCharacter {
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                break
            default:
                throw JSONError.unexpectedCharacter(ascii: extraCharacter, characterIndex: reader.index)
            }
        }

        while let (byte, index) = reader.read() {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                continue
            default:
                throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
            }
        }

        return value
    }

    // MARK: Generic Value Parsing

    mutating func parseValue() throws -> JSONValue {
        while let (byte, index) = reader.read() {
            switch byte {
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "{"):
                let object = try parseObject()
                return .object(object)
            case UInt8(ascii: "["):
                let array = try parseArray()
                return .array(array)
            case UInt8(ascii: "f"), UInt8(ascii: "t"):
                let bool = try parseBool()
                return .bool(bool)
            case UInt8(ascii: "n"):
                try parseNull()
                return .null

            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                let number = try parseNumber()
                return .number(number)
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                continue
            default:
                throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
            }
        }

        throw JSONError.unexpectedEndOfFile
    }

    // MARK: - Parse Null -

    mutating func parseNull() throws {
        guard reader.read()?.0 == UInt8(ascii: "u"),
            reader.read()?.0 == UInt8(ascii: "l"),
            reader.read()?.0 == UInt8(ascii: "l")
        else {
            guard let value = reader.value else {
                throw JSONError.unexpectedEndOfFile
            }

            throw JSONError.unexpectedCharacter(ascii: value, characterIndex: reader.index)
        }
    }

    // MARK: - Parse Bool -

    mutating func parseBool() throws -> Bool {
        switch reader.value {
        case UInt8(ascii: "t"):
            guard reader.read()?.0 == UInt8(ascii: "r"),
                reader.read()?.0 == UInt8(ascii: "u"),
                reader.read()?.0 == UInt8(ascii: "e")
            else {
                guard let value = reader.value else {
                    throw JSONError.unexpectedEndOfFile
                }

                throw JSONError.unexpectedCharacter(ascii: value, characterIndex: reader.index)
            }

            return true
        case UInt8(ascii: "f"):
            guard reader.read()?.0 == UInt8(ascii: "a"),
                reader.read()?.0 == UInt8(ascii: "l"),
                reader.read()?.0 == UInt8(ascii: "s"),
                reader.read()?.0 == UInt8(ascii: "e")
            else {
                guard let value = reader.value else {
                    throw JSONError.unexpectedEndOfFile
                }

                throw JSONError.unexpectedCharacter(ascii: value, characterIndex: reader.index)
            }

            return false
        default:
            preconditionFailure("Expected to have `t` or `f` as first character")
        }
    }

    // MARK: - Parse String -

    mutating func parseString() throws -> String {
        return try reader.readUTF8StringTillNextUnescapedQuote()
    }

    // MARK: - Parse Number -

    enum ControlCharacter {
        case operand
        case decimalPoint
        case exp
        case expOperator
    }

    mutating func parseNumber() throws -> String {
        var pastControlChar: ControlCharacter = .operand
        var numbersSinceControlChar: UInt = 0
        var hasLeadingZero = false

        // parse first character

        let stringStartIndex = reader.index
        switch reader.value! {
        case UInt8(ascii: "0"):
            numbersSinceControlChar = 1
            pastControlChar = .operand
            hasLeadingZero = true
        case UInt8(ascii: "1") ... UInt8(ascii: "9"):
            numbersSinceControlChar = 1
            pastControlChar = .operand
        case UInt8(ascii: "-"):
            numbersSinceControlChar = 0
            pastControlChar = .operand
        default:
            preconditionFailure("This state should never be reached")
        }

        // parse everything else

        while let (byte, index) = reader.read() {
            switch byte {
            case UInt8(ascii: "0"):
                if hasLeadingZero {
                    throw JSONError.numberWithLeadingZero(index: index)
                }
                if numbersSinceControlChar == 0, pastControlChar == .operand {
                    // the number started with a minus. this is the leading zero.
                    hasLeadingZero = true
                }
                numbersSinceControlChar += 1
            case UInt8(ascii: "1") ... UInt8(ascii: "9"):
                if hasLeadingZero {
                    throw JSONError.numberWithLeadingZero(index: index)
                }
                numbersSinceControlChar += 1
            case UInt8(ascii: "."):
                guard numbersSinceControlChar > 0, pastControlChar == .operand else {
                    throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                }

                hasLeadingZero = false

                pastControlChar = .decimalPoint
                numbersSinceControlChar = 0

            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                guard numbersSinceControlChar > 0,
                    pastControlChar == .operand || pastControlChar == .decimalPoint
                else {
                    throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                }

                hasLeadingZero = false

                pastControlChar = .exp
                numbersSinceControlChar = 0
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                guard numbersSinceControlChar == 0, pastControlChar == .exp else {
                    throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                }

                pastControlChar = .expOperator
                numbersSinceControlChar = 0
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                guard numbersSinceControlChar > 0 else {
                    throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                }

                return reader.makeStringFast(reader[stringStartIndex ..< index])
            case UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"):
                guard numbersSinceControlChar > 0 else {
                    throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                }

                return reader.makeStringFast(reader[stringStartIndex ..< index])
            default:
                throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
            }
        }

        guard numbersSinceControlChar > 0 else {
            throw JSONError.unexpectedEndOfFile
        }

        return String(decoding: reader.remainingBytes(from: stringStartIndex), as: Unicode.UTF8.self)
    }

    // MARK: - Parse Array -

    enum ArrayState {
        case expectValueOrEnd
        case expectValue
        case expectSeperatorOrEnd
    }

    mutating func parseArray() throws -> [JSONValue] {
        assert(reader.value == UInt8(ascii: "["))
        guard depth < 512 else {
            throw JSONError.tooManyNestedArraysOrDictionaries(characterIndex: reader.index)
        }
        depth += 1
        defer { depth -= 1 }
        var state = ArrayState.expectValueOrEnd

        var array = [JSONValue]()
        array.reserveCapacity(10)

        // parse first value or immidiate end

        do {
            let value = try parseValue()
            array.append(value)

            if case .number = value {
                guard let extraByte = reader.value else {
                    throw JSONError.unexpectedEndOfFile
                }

                switch extraByte {
                case UInt8(ascii: ","):
                    state = .expectValue
                case UInt8(ascii: "]"):
                    return array
                case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                    state = .expectSeperatorOrEnd
                default:
                    throw JSONError.unexpectedCharacter(ascii: extraByte, characterIndex: reader.index)
                }
            } else {
                state = .expectSeperatorOrEnd
            }
        } catch JSONError.unexpectedCharacter(ascii: UInt8(ascii: "]"), _) {
            return []
        }

        // parse further

        while true {
            switch state {
            case .expectSeperatorOrEnd:
                // parsing for seperator or end

                seperatorloop: while let (byte, index) = reader.read() {
                    switch byte {
                    case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                        continue
                    case UInt8(ascii: "]"):
                        return array
                    case UInt8(ascii: ","):
                        state = .expectValue
                        break seperatorloop
                    default:
                        throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                    }
                }

                if state != .expectValue {
                    throw JSONError.unexpectedEndOfFile
                }
            case .expectValue:
                let value = try parseValue()
                array.append(value)

                guard case .number = value else {
                    state = .expectSeperatorOrEnd
                    continue
                }

                guard let extraByte = reader.value else {
                    throw JSONError.unexpectedEndOfFile
                }

                switch extraByte {
                case UInt8(ascii: ","):
                    state = .expectValue
                case UInt8(ascii: "]"):
                    return array
                case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                    state = .expectSeperatorOrEnd
                default:
                    throw JSONError.unexpectedCharacter(ascii: extraByte, characterIndex: reader.index)
                }
            case .expectValueOrEnd:
                preconditionFailure("this state should not be reachable at this point")
            }
        }
    }

    // MARK: - Object parsing -

    enum ObjectState: Equatable {
        case expectKeyOrEnd
        case expectKey
        case expectColon(key: String)
        case expectValue(key: String)
        case expectSeperatorOrEnd
    }

    mutating func parseObject() throws -> [String: JSONValue] {
        assert(reader.value == UInt8(ascii: "{"))
        guard depth < 512 else {
            throw JSONError.tooManyNestedArraysOrDictionaries(characterIndex: reader.index)
        }
        depth += 1
        defer { depth -= 1 }

        var state = ObjectState.expectKeyOrEnd

        // parse first key or end immidiatly
        loop: while let (byte, index) = reader.read() {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                continue
            case UInt8(ascii: "\""):
                state = .expectColon(key: try parseString())
                break loop
            case UInt8(ascii: "}"):
                return [:]
            default:
                throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
            }
        }

        guard case .expectColon = state else {
            throw JSONError.unexpectedEndOfFile
        }

        var object = [String: JSONValue]()
        object.reserveCapacity(20)

        while true {
            switch state {
            case .expectKey:
                keyloop: while let (byte, index) = reader.read() {
                    switch byte {
                    case UInt8(ascii: "\""):
                        let key = try parseString()
                        state = .expectColon(key: key)
                        break keyloop
                    case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                        continue
                    default:
                        throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                    }
                }

                guard case .expectColon = state else {
                    throw JSONError.unexpectedEndOfFile
                }

            case let .expectColon(key):
                colonloop: while let (byte, index) = reader.read() {
                    switch byte {
                    case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                        continue
                    case UInt8(ascii: ":"):
                        state = .expectValue(key: key)
                        break colonloop
                    default:
                        throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                    }
                }

                guard case .expectValue = state else {
                    throw JSONError.unexpectedEndOfFile
                }

            case let .expectValue(key):
                let value = try parseValue()
                object[key] = value

                // special handling for numbers
                guard case .number = value else {
                    state = .expectSeperatorOrEnd
                    continue
                }

                guard let extraByte = reader.value else {
                    throw JSONError.unexpectedEndOfFile
                }

                switch extraByte {
                case UInt8(ascii: ","):
                    state = .expectKey
                case UInt8(ascii: "}"):
                    return object
                case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                    state = .expectSeperatorOrEnd
                default:
                    throw JSONError.unexpectedCharacter(ascii: extraByte, characterIndex: reader.index)
                }

            case .expectSeperatorOrEnd:
                seperatorloop: while let (byte, index) = reader.read() {
                    switch byte {
                    case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                        continue
                    case UInt8(ascii: "}"):
                        return object
                    case UInt8(ascii: ","):
                        state = .expectKey
                        break seperatorloop
                    default:
                        throw JSONError.unexpectedCharacter(ascii: byte, characterIndex: index)
                    }
                }

                guard case .expectKey = state else {
                    throw JSONError.unexpectedEndOfFile
                }
            case .expectKeyOrEnd:
                preconditionFailure("this state should be unreachable here")
            }
        }
    }
}
