import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

enum BackgroundRemovalError: LocalizedError {
    case noForeground
    case cannotCreateImage
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .noForeground:
            "Не удалось уверенно найти главный объект. Попробуйте изображение, где объект заметнее отличается от фона."
        case .cannotCreateImage:
            "Не удалось сформировать изображение с прозрачным фоном."
        case .cannotEncodePNG:
            "Не удалось подготовить PNG для сохранения."
        }
    }
}

enum BackgroundRemovalService {
    private struct ChromaBackground {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let transparentDistance: CGFloat
        let opaqueDistance: CGFloat
        let dominantChannel: Int?
        let opaqueDominance: CGFloat
        let transparentDominance: CGFloat
    }

    private static let context = CIContext(options: [
        .cacheIntermediates: true,
        .useSoftwareRenderer: false
    ])

    static func removeBackground(from source: CGImage) throws -> CGImage {
        if let chromaResult = try removeChromaBackground(from: source) {
            return chromaResult
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw BackgroundRemovalError.noForeground
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )

        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let sourceImage = CIImage(cgImage: source)
        let sourceMask = CIImage(cvPixelBuffer: maskBuffer).cropped(to: extent)

        // Preserve Vision's silhouette. A small blur only smooths subpixel transitions;
        // morphology/erosion here would visibly eat thin details and hard object edges.
        let resolutionScale = max(CGFloat(source.width), CGFloat(source.height)) / 1440
        let featherRadius = min(max(0.35 * resolutionScale, 0.25), 0.65)

        let cleanedMask = sourceMask
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: featherRadius]
            )
            .cropped(to: extent)

        let colorSearchRadius = min(max(Int(ceil(2 * resolutionScale)), 2), 4)
        return try makeDecontaminatedImage(
            source: sourceImage,
            mask: cleanedMask,
            width: source.width,
            height: source.height,
            colorSearchRadius: colorSearchRadius,
            despillChannel: nil
        )
    }

    static func centeredPreviewCrop(from source: CGImage) -> CGImage {
        let width = source.width
        let height = source.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return source }

        let image = CIImage(cgImage: source)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                image,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                guard alpha >= 12 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }

        guard maximumX >= minimumX, maximumY >= minimumY else { return source }

        let contentWidth = maximumX - minimumX + 1
        let contentHeight = maximumY - minimumY + 1
        let padding = max(12, Int((CGFloat(max(contentWidth, contentHeight)) * 0.04).rounded()))
        let cropMinimumX = max(0, minimumX - padding)
        let cropMinimumY = max(0, minimumY - padding)
        let cropMaximumX = min(width - 1, maximumX + padding)
        let cropMaximumY = min(height - 1, maximumY + padding)
        let coreImageMinimumY = height - cropMaximumY - 1
        let cropRect = CGRect(
            x: cropMinimumX,
            y: coreImageMinimumY,
            width: cropMaximumX - cropMinimumX + 1,
            height: cropMaximumY - cropMinimumY + 1
        )

        guard cropRect.width < CGFloat(width) || cropRect.height < CGFloat(height),
              let cropped = context.createCGImage(image, from: cropRect) else {
            return source
        }
        return cropped
    }

    private static func removeChromaBackground(from source: CGImage) throws -> CGImage? {
        let width = source.width
        let height = source.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BackgroundRemovalError.cannotCreateImage
        }

        let sourceImage = CIImage(cgImage: source)
        var sourcePixels = [UInt8](repeating: 0, count: width * height * 4)
        sourcePixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                sourceImage,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        guard let background = detectChromaBackground(
            pixels: sourcePixels,
            width: width,
            height: height
        ) else {
            return nil
        }

        var maskPixels = [UInt8](repeating: 0, count: width * height)
        let distanceRange = max(background.opaqueDistance - background.transparentDistance, 1)

        for pixelIndex in 0..<(width * height) {
            let colorIndex = pixelIndex * 4
            let linearAlpha: CGFloat

            if let dominantChannel = background.dominantChannel {
                let red = CGFloat(sourcePixels[colorIndex])
                let green = CGFloat(sourcePixels[colorIndex + 1])
                let blue = CGFloat(sourcePixels[colorIndex + 2])
                let channels = [red, green, blue]
                let dominant = channels[dominantChannel]
                let strongestOther = channels.enumerated()
                    .filter { $0.offset != dominantChannel }
                    .map(\.element)
                    .max() ?? 0
                let dominance = dominant - strongestOther
                let dominanceRange = max(
                    background.transparentDominance - background.opaqueDominance,
                    1
                )
                let keyedAmount = min(
                    max((dominance - background.opaqueDominance) / dominanceRange, 0),
                    1
                )
                linearAlpha = 1 - keyedAmount
            } else {
                let chroma = chromaticity(
                    red: sourcePixels[colorIndex],
                    green: sourcePixels[colorIndex + 1],
                    blue: sourcePixels[colorIndex + 2]
                )
                let distance = chromaDistance(
                    chroma,
                    (background.red, background.green, background.blue)
                )
                linearAlpha = min(
                    max((distance - background.transparentDistance) / distanceRange, 0),
                    1
                )
            }

            let smoothAlpha = linearAlpha * linearAlpha * (3 - 2 * linearAlpha)
            if smoothAlpha <= 0.015 {
                maskPixels[pixelIndex] = 0
            } else if smoothAlpha >= 0.985 {
                maskPixels[pixelIndex] = 255
            } else {
                maskPixels[pixelIndex] = UInt8((smoothAlpha * 255).rounded())
            }
        }

        let maskData = Data(maskPixels)
        let maskImage = CIImage(
            bitmapData: maskData,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: nil
        )
        .cropped(to: extent)

        return try makeDecontaminatedImage(
            source: sourceImage,
            mask: maskImage,
            width: width,
            height: height,
            colorSearchRadius: 4,
            despillChannel: background.dominantChannel
        )
    }

    private static func detectChromaBackground(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> ChromaBackground? {
        guard width >= 32, height >= 32 else { return nil }

        let stride = max(1, min(width, height) / 600)
        var borderChromas: [(CGFloat, CGFloat, CGFloat)] = []
        var borderSaturations: [CGFloat] = []

        func appendPixel(x: Int, y: Int) {
            let index = (y * width + x) * 4
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            borderChromas.append(chromaticity(red: red, green: green, blue: blue))

            let maximum = CGFloat(max(red, green, blue))
            let minimum = CGFloat(min(red, green, blue))
            borderSaturations.append(maximum > 0 ? (maximum - minimum) / maximum : 0)
        }

        for x in Swift.stride(from: 0, to: width, by: stride) {
            appendPixel(x: x, y: 0)
            appendPixel(x: x, y: height - 1)
        }
        for y in Swift.stride(from: stride, to: height - stride, by: stride) {
            appendPixel(x: 0, y: y)
            appendPixel(x: width - 1, y: y)
        }

        guard !borderChromas.isEmpty else { return nil }

        let sampleCount = CGFloat(borderChromas.count)
        let average = borderChromas.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) { partial, value in
            (partial.0 + value.0, partial.1 + value.1, partial.2 + value.2)
        }
        let backgroundChroma = (
            average.0 / sampleCount,
            average.1 / sampleCount,
            average.2 / sampleCount
        )
        let averageSaturation = borderSaturations.reduce(0, +) / CGFloat(borderSaturations.count)

        // The chroma-key path is deliberately conservative. It is used only when the
        // perimeter is strongly saturated and consistent; normal photos stay on Vision.
        guard averageSaturation >= 0.42 else { return nil }

        let distances = borderChromas
            .map { chromaDistance($0, backgroundChroma) }
            .sorted()
        let percentile95 = distances[min(Int(CGFloat(distances.count - 1) * 0.95), distances.count - 1)]
        guard percentile95 <= 18 else { return nil }

        let cornerInsetX = max(2, width / 50)
        let cornerInsetY = max(2, height / 50)
        let corners = [
            chromaticityAt(pixels: pixels, width: width, x: cornerInsetX, y: cornerInsetY),
            chromaticityAt(pixels: pixels, width: width, x: width - cornerInsetX - 1, y: cornerInsetY),
            chromaticityAt(pixels: pixels, width: width, x: cornerInsetX, y: height - cornerInsetY - 1),
            chromaticityAt(
                pixels: pixels,
                width: width,
                x: width - cornerInsetX - 1,
                y: height - cornerInsetY - 1
            )
        ]
        guard corners.allSatisfy({ chromaDistance($0, backgroundChroma) <= 22 }) else {
            return nil
        }

        let transparentDistance = max(percentile95 * 1.35 + 2, 8)
        let opaqueDistance = transparentDistance + 30

        let chromaChannels = [backgroundChroma.0, backgroundChroma.1, backgroundChroma.2]
        let sortedChannelIndexes = chromaChannels.indices.sorted {
            chromaChannels[$0] > chromaChannels[$1]
        }
        var dominantChannel: Int?
        var opaqueDominance: CGFloat = 0
        var transparentDominance: CGFloat = 0

        if let strongestIndex = sortedChannelIndexes.first,
           sortedChannelIndexes.count > 1,
           chromaChannels[strongestIndex] - chromaChannels[sortedChannelIndexes[1]] >= 0.25 {
            let dominanceValues = borderChromas.map { chroma -> CGFloat in
                let channels = [chroma.0, chroma.1, chroma.2]
                let strongestOther = channels.enumerated()
                    .filter { $0.offset != strongestIndex }
                    .map(\.element)
                    .max() ?? 0
                return (channels[strongestIndex] - strongestOther) * 255
            }
            .sorted()
            let percentile05 = dominanceValues[min(
                Int(CGFloat(dominanceValues.count - 1) * 0.05),
                dominanceValues.count - 1
            )]

            if percentile05 >= 55 {
                dominantChannel = strongestIndex
                opaqueDominance = max(10, percentile05 * 0.12)
                transparentDominance = max(opaqueDominance + 35, percentile05 * 0.78)
            }
        }

        return ChromaBackground(
            red: backgroundChroma.0,
            green: backgroundChroma.1,
            blue: backgroundChroma.2,
            transparentDistance: transparentDistance,
            opaqueDistance: opaqueDistance,
            dominantChannel: dominantChannel,
            opaqueDominance: opaqueDominance,
            transparentDominance: transparentDominance
        )
    }

    private static func chromaticity(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> (CGFloat, CGFloat, CGFloat) {
        let total = max(CGFloat(red) + CGFloat(green) + CGFloat(blue), 1)
        return (CGFloat(red) / total, CGFloat(green) / total, CGFloat(blue) / total)
    }

    private static func chromaticityAt(
        pixels: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> (CGFloat, CGFloat, CGFloat) {
        let index = (y * width + x) * 4
        return chromaticity(
            red: pixels[index],
            green: pixels[index + 1],
            blue: pixels[index + 2]
        )
    }

    private static func chromaDistance(
        _ lhs: (CGFloat, CGFloat, CGFloat),
        _ rhs: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let red = lhs.0 - rhs.0
        let green = lhs.1 - rhs.1
        let blue = lhs.2 - rhs.2
        return sqrt(red * red + green * green + blue * blue) * 255
    }

    private static func makeDecontaminatedImage(
        source: CIImage,
        mask: CIImage,
        width: Int,
        height: Int,
        colorSearchRadius: Int,
        despillChannel: Int?
    ) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BackgroundRemovalError.cannotCreateImage
        }

        var sourcePixels = [UInt8](repeating: 0, count: width * height * 4)
        var maskPixels = [UInt8](repeating: 0, count: width * height)

        sourcePixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                source,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        maskPixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                mask,
                toBitmap: baseAddress,
                rowBytes: width,
                bounds: extent,
                format: .R8,
                colorSpace: nil
            )
        }

        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * width + x
                let alpha = maskPixels[pixelIndex]
                let outputIndex = pixelIndex * 4

                guard alpha > 0 else { continue }

                var colorPixelIndex = pixelIndex

                // Fully opaque pixels already contain uncontaminated foreground color.
                // At a soft edge, find the closest nearby pixel with the strongest mask
                // confidence and borrow only its RGB. The original smooth alpha is kept.
                if alpha < 250 {
                    var bestAlpha = alpha
                    var bestDistanceSquared = Int.max

                    let minimumY = max(0, y - colorSearchRadius)
                    let maximumY = min(height - 1, y + colorSearchRadius)
                    let minimumX = max(0, x - colorSearchRadius)
                    let maximumX = min(width - 1, x + colorSearchRadius)

                    for candidateY in minimumY...maximumY {
                        for candidateX in minimumX...maximumX {
                            let candidateIndex = candidateY * width + candidateX
                            let candidateAlpha = maskPixels[candidateIndex]
                            let deltaX = candidateX - x
                            let deltaY = candidateY - y
                            let distanceSquared = deltaX * deltaX + deltaY * deltaY

                            if candidateAlpha > bestAlpha ||
                                (candidateAlpha == bestAlpha && distanceSquared < bestDistanceSquared) {
                                bestAlpha = candidateAlpha
                                bestDistanceSquared = distanceSquared
                                colorPixelIndex = candidateIndex
                            }
                        }
                    }
                }

                let colorIndex = colorPixelIndex * 4
                var colors = [
                    Int(sourcePixels[colorIndex]),
                    Int(sourcePixels[colorIndex + 1]),
                    Int(sourcePixels[colorIndex + 2])
                ]
                var outputAlpha = Int(alpha)

                if let despillChannel, alpha < 255 {
                    let strongestOther = colors.enumerated()
                        .filter { $0.offset != despillChannel }
                        .map(\.element)
                        .max() ?? 0
                    let spill = max(colors[despillChannel] - strongestOther, 0)

                    if spill > 0 {
                        let spillRatio = CGFloat(spill) / CGFloat(max(colors[despillChannel], 1))
                        outputAlpha = Int(
                            (CGFloat(outputAlpha) * (1 - min(spillRatio * 0.9, 0.9))).rounded()
                        )
                        colors[despillChannel] = strongestOther
                    }
                }

                // CGImage uses premultiplied RGBA. Keeping transparent RGB premultiplied
                // avoids bright seams when other apps composite the PNG on a dark color.
                outputPixels[outputIndex] = UInt8((colors[0] * outputAlpha + 127) / 255)
                outputPixels[outputIndex + 1] = UInt8((colors[1] * outputAlpha + 127) / 255)
                outputPixels[outputIndex + 2] = UInt8((colors[2] * outputAlpha + 127) / 255)
                outputPixels[outputIndex + 3] = UInt8(outputAlpha)
            }
        }

        guard let provider = CGDataProvider(data: Data(outputPixels) as CFData),
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
            throw BackgroundRemovalError.cannotCreateImage
        }

        return image
    }
}
