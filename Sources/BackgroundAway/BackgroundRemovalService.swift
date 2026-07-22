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
    struct CompositionLayer {
        let image: CGImage
        let offset: CGSize
        let scale: CGFloat
    }

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

    static func applyingMaskStroke(
        to result: CGImage,
        restoringFrom source: CGImage,
        normalizedPoints: [CGPoint],
        radius: CGFloat,
        restoresPixels: Bool
    ) throws -> CGImage {
        guard !normalizedPoints.isEmpty,
              result.width == source.width,
              result.height == source.height else {
            return result
        }

        let width = result.width
        let height = result.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let grayColorSpace = CGColorSpaceCreateDeviceGray()

        guard let maskContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw BackgroundRemovalError.cannotCreateImage
        }

        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(extent)
        maskContext.setAllowsAntialiasing(true)
        maskContext.setShouldAntialias(true)
        maskContext.setStrokeColor(gray: 1, alpha: 1)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.setLineCap(.round)
        maskContext.setLineJoin(.round)
        maskContext.setLineWidth(max(radius * 2, 1))

        let pixelPoints = normalizedPoints.map { point in
            CGPoint(
                x: min(max(point.x, 0), 1) * CGFloat(max(width - 1, 1)),
                y: (1 - min(max(point.y, 0), 1)) * CGFloat(max(height - 1, 1))
            )
        }

        if let firstPoint = pixelPoints.first {
            if pixelPoints.count == 1 {
                let diameter = max(radius * 2, 1)
                maskContext.fillEllipse(in: CGRect(
                    x: firstPoint.x - diameter / 2,
                    y: firstPoint.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            } else {
                maskContext.move(to: firstPoint)
                for point in pixelPoints.dropFirst() {
                    maskContext.addLine(to: point)
                }
                maskContext.strokePath()
            }
        }

        guard let strokeMask = maskContext.makeImage() else {
            throw BackgroundRemovalError.cannotCreateImage
        }

        let featherRadius = min(max(radius * 0.08, 0.75), 6)
        let maskImage = CIImage(cgImage: strokeMask)
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: featherRadius]
            )
            .cropped(to: extent)

        let resultImage = CIImage(cgImage: result)
        let replacementImage = restoresPixels
            ? CIImage(cgImage: source)
            : CIImage(color: .clear).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = replacementImage
        blend.backgroundImage = resultImage
        blend.maskImage = maskImage

        guard let output = blend.outputImage?.cropped(to: extent),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw BackgroundRemovalError.cannotCreateImage
        }
        return rendered
    }

    static func refiningEdges(
        of base: CGImage,
        featherRadius: CGFloat,
        edgeShift: CGFloat,
        haloCleanup: CGFloat
    ) throws -> CGImage {
        try Task.checkCancellation()

        let width = base.width
        let height = base.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BackgroundRemovalError.cannotCreateImage
        }

        var basePixels = [UInt8](repeating: 0, count: width * height * 4)
        basePixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                CIImage(cgImage: base),
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        var baseAlpha = [UInt8](repeating: 0, count: width * height)
        for pixelIndex in 0..<(width * height) {
            if pixelIndex.isMultiple(of: 65_536) {
                try Task.checkCancellation()
            }
            baseAlpha[pixelIndex] = basePixels[pixelIndex * 4 + 3]
        }

        var refinedMask = CIImage(
            bitmapData: Data(baseAlpha),
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: nil
        )
        .cropped(to: extent)

        let safeShift = min(max(edgeShift, -8), 8)
        if abs(safeShift) >= 0.01 {
            refinedMask = refinedMask
                .clampedToExtent()
                .applyingFilter(
                    safeShift < 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum",
                    parameters: [kCIInputRadiusKey: abs(safeShift)]
                )
                .cropped(to: extent)
        }

        let safeFeather = min(max(featherRadius, 0), 8)
        if safeFeather >= 0.01 {
            refinedMask = refinedMask
                .clampedToExtent()
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: safeFeather]
                )
                .cropped(to: extent)
        }

        var refinedAlpha = [UInt8](repeating: 0, count: width * height)
        refinedAlpha.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                refinedMask,
                toBitmap: baseAddress,
                rowBytes: width,
                bounds: extent,
                format: .R8,
                colorSpace: nil
            )
        }

        let cleanup = min(max(haloCleanup, 0), 1)
        let searchRadius = min(
            max(Int(ceil(abs(safeShift) + safeFeather * 3 + 2)), 2),
            12
        )
        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)

        func straightComponent(_ value: UInt8, alpha: UInt8) -> CGFloat {
            guard alpha > 0 else { return 0 }
            return min(CGFloat(value) * 255 / CGFloat(alpha), 255)
        }

        for y in 0..<height {
            if y.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            for x in 0..<width {
                let pixelIndex = y * width + x
                var newAlpha = refinedAlpha[pixelIndex]
                if newAlpha <= 1 {
                    continue
                }
                if newAlpha >= 254 {
                    newAlpha = 255
                }

                let sourceIndex = pixelIndex * 4
                let oldAlpha = baseAlpha[pixelIndex]
                if newAlpha == 255, oldAlpha == 255 {
                    outputPixels[sourceIndex] = basePixels[sourceIndex]
                    outputPixels[sourceIndex + 1] = basePixels[sourceIndex + 1]
                    outputPixels[sourceIndex + 2] = basePixels[sourceIndex + 2]
                    outputPixels[sourceIndex + 3] = 255
                    continue
                }

                var interiorPixelIndex = pixelIndex
                var bestAlpha = oldAlpha
                var bestDistanceSquared = Int.max

                if oldAlpha == 0 || cleanup > 0 {
                    let minimumY = max(0, y - searchRadius)
                    let maximumY = min(height - 1, y + searchRadius)
                    let minimumX = max(0, x - searchRadius)
                    let maximumX = min(width - 1, x + searchRadius)

                    for candidateY in minimumY...maximumY {
                        for candidateX in minimumX...maximumX {
                            let candidateIndex = candidateY * width + candidateX
                            let candidateAlpha = baseAlpha[candidateIndex]
                            let deltaX = candidateX - x
                            let deltaY = candidateY - y
                            let distanceSquared = deltaX * deltaX + deltaY * deltaY

                            if candidateAlpha > bestAlpha ||
                                (candidateAlpha == bestAlpha &&
                                    distanceSquared < bestDistanceSquared) {
                                bestAlpha = candidateAlpha
                                bestDistanceSquared = distanceSquared
                                interiorPixelIndex = candidateIndex
                            }
                        }
                    }
                }

                let interiorIndex = interiorPixelIndex * 4
                let interiorAlpha = baseAlpha[interiorPixelIndex]
                let forcedInterior = oldAlpha == 0
                let edgeAlpha = CGFloat(min(oldAlpha, newAlpha)) / 255
                let normalizedAlpha = min(max((edgeAlpha - 0.55) / 0.43, 0), 1)
                let smoothAlpha = normalizedAlpha * normalizedAlpha * (3 - 2 * normalizedAlpha)
                let mix = forcedInterior ? CGFloat(1) : cleanup * (1 - smoothAlpha)

                for component in 0..<3 {
                    let edgeColor = oldAlpha > 0
                        ? straightComponent(
                            basePixels[sourceIndex + component],
                            alpha: oldAlpha
                        )
                        : straightComponent(
                            basePixels[interiorIndex + component],
                            alpha: interiorAlpha
                        )
                    let interiorColor = straightComponent(
                        basePixels[interiorIndex + component],
                        alpha: interiorAlpha
                    )
                    let color = edgeColor + (interiorColor - edgeColor) * mix
                    outputPixels[sourceIndex + component] = UInt8(
                        min(max((color * CGFloat(newAlpha) / 255).rounded(), 0), 255)
                    )
                }
                outputPixels[sourceIndex + 3] = newAlpha
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

    static func compose(
        layers: [CompositionLayer],
        canvasSize: CGSize
    ) throws -> CGImage {
        let width = max(Int(canvasSize.width.rounded()), 1)
        let height = max(Int(canvasSize.height.rounded()), 1)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var composition = CIImage(color: .clear).cropped(to: extent)

        for layer in layers {
            let scale = max(layer.scale, 0.001)
            let scaled = CIImage(cgImage: layer.image)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let originX = CGFloat(width) / 2 + layer.offset.width - scaled.extent.width / 2
            let originY = CGFloat(height) / 2 - layer.offset.height - scaled.extent.height / 2
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: originX - scaled.extent.minX,
                y: originY - scaled.extent.minY
            ))
            composition = positioned.composited(over: composition)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(
                  composition.cropped(to: extent),
                  from: extent,
                  format: .RGBA8,
                  colorSpace: colorSpace
              ) else {
            throw BackgroundRemovalError.cannotCreateImage
        }
        return rendered
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
