import Foundation

extension JSONDecoder {
    public static let imageRelay: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

extension JSONEncoder {
    public static let imageRelay: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
