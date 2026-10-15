//
//  IceColor.swift
//  Ice
//

import CoreGraphics
import Foundation

/// A custom color.
struct IceColor: Hashable {
    /// The color, represented as a `CGColor`.
    var cgColor: CGColor
}

// MARK: IceColor: Codable
extension IceColor: Codable {
    private enum CodingKeys: CodingKey {
        case components
        case colorSpace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var components = try container.decode([CGFloat].self, forKey: .components)
        let iccData = try container.decode(Data.self, forKey: .colorSpace) as CFData
        guard let colorSpace = CGColorSpace(iccData: iccData) else {
            throw DecodingError.dataCorruptedError(
                forKey: .colorSpace,
                in: container,
                debugDescription: "Invalid ICC profile data"
            )
        }
        // CGColor reads one value per color space component, plus alpha,
        // without checking the array's length. A stored or imported color
        // with fewer values made it read past the end of the array.
        guard components.count >= colorSpace.numberOfComponents + 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .components,
                in: container,
                debugDescription: "Expected at least \(colorSpace.numberOfComponents + 1) color components, found \(components.count)"
            )
        }
        guard let cgColor = CGColor(colorSpace: colorSpace, components: &components) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid color space or components"
                )
            )
        }
        self.cgColor = cgColor
    }

    func encode(to encoder: Encoder) throws {
        guard let components = cgColor.components else {
            throw EncodingError.invalidValue(
                cgColor,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Missing color components"
                )
            )
        }
        guard let colorSpace = cgColor.colorSpace else {
            throw EncodingError.invalidValue(
                cgColor,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Missing color space"
                )
            )
        }
        guard let iccData = colorSpace.copyICCData() else {
            throw EncodingError.invalidValue(
                colorSpace,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Missing ICC profile data"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(components, forKey: .components)
        try container.encode(iccData as Data, forKey: .colorSpace)
    }
}
