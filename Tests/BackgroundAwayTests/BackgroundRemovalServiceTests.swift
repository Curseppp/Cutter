import CoreGraphics
import XCTest
@testable import BackgroundAway

final class BackgroundRemovalServiceTests: XCTestCase {
    func testChromaKeyPreservesObjectAndClearsConnectedAndInternalBackground() throws {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let isForeground = (24..<104).contains(x) && (18..<110).contains(y)
                let isInternalHole = (56..<72).contains(x) && (50..<78).contains(y)

                if isForeground && !isInternalHole {
                    pixels[index] = 250
                    pixels[index + 1] = 150
                    pixels[index + 2] = 190
                } else {
                    pixels[index] = 0
                    pixels[index + 1] = 255
                    pixels[index + 2] = 0
                }
                pixels[index + 3] = 255
            }
        }

        let input = try makeImage(pixels: pixels, width: width, height: height)
        let output = try BackgroundRemovalService.removeBackground(from: input)
        let outputPixels = try rgbaPixels(from: output)

        XCTAssertEqual(output.width, width)
        XCTAssertEqual(output.height, height)
        XCTAssertLessThan(alpha(atX: 4, y: 4, width: width, pixels: outputPixels), 5)
        XCTAssertGreaterThan(alpha(atX: 40, y: 40, width: width, pixels: outputPixels), 250)
        XCTAssertLessThan(alpha(atX: 64, y: 64, width: width, pixels: outputPixels), 5)
    }

    func testChromaKeyRemovesGreenSpillFromTranslucentEdge() throws {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let isForeground = (32..<96).contains(x) && (24..<104).contains(y)
                let isMixedEdge = ((x == 31 || x == 96) && (23...104).contains(y)) ||
                    ((y == 23 || y == 104) && (31...96).contains(x))

                if isForeground {
                    pixels[index] = 250
                    pixels[index + 1] = 150
                    pixels[index + 2] = 190
                } else if isMixedEdge {
                    pixels[index] = 125
                    pixels[index + 1] = 203
                    pixels[index + 2] = 95
                } else {
                    pixels[index] = 0
                    pixels[index + 1] = 255
                    pixels[index + 2] = 0
                }
                pixels[index + 3] = 255
            }
        }

        let input = try makeImage(pixels: pixels, width: width, height: height)
        let output = try BackgroundRemovalService.removeBackground(from: input)
        let outputPixels = try rgbaPixels(from: output)
        let edgeIndex = (64 * width + 31) * 4
        let edgeAlpha = Int(outputPixels[edgeIndex + 3])

        XCTAssertGreaterThan(edgeAlpha, 5)
        XCTAssertLessThan(edgeAlpha, 250)

        let red = Int(outputPixels[edgeIndex]) * 255 / edgeAlpha
        let green = Int(outputPixels[edgeIndex + 1]) * 255 / edgeAlpha
        let blue = Int(outputPixels[edgeIndex + 2]) * 255 / edgeAlpha
        XCTAssertLessThanOrEqual(green, max(red, blue) + 2)
    }

    private func makeImage(pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                      .union(.byteOrder32Big),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw TestError.cannotCreateImage
        }
        return image
    }

    private func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)

        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                  let context = CGContext(
                      data: address,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }

        guard created else { throw TestError.cannotReadImage }
        return pixels
    }

    private func alpha(atX x: Int, y: Int, width: Int, pixels: [UInt8]) -> UInt8 {
        pixels[(y * width + x) * 4 + 3]
    }

    private enum TestError: Error {
        case cannotCreateImage
        case cannotReadImage
    }
}
