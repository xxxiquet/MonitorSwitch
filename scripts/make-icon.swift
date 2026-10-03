import AppKit
import Foundation
let folder = CommandLine.arguments[1]
let menuBar = ProcessInfo.processInfo.environment["MONITORSWITCH_MENU_BAR"] == "1"
let fm = FileManager.default
try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let n=CGFloat(size)
    if menuBar {
        let transform = NSAffineTransform()
        transform.translateX(by: n * 0.5, yBy: n * 0.5)
        transform.scale(by: 1.4)
        transform.translateX(by: -n * 0.5, yBy: -n * 0.5)
        transform.concat()
    } else {
        NSColor.black.setFill()
        NSBezierPath(roundedRect:NSRect(x:n*0.06,y:n*0.06,width:n*0.88,height:n*0.88),xRadius:n*0.2,yRadius:n*0.2).fill()
    }
    let frame=NSBezierPath(roundedRect:NSRect(x:n*0.19,y:n*0.31,width:n*0.62,height:n*0.42),xRadius:n*0.055,yRadius:n*0.055)
    NSColor.white.setStroke(); frame.lineWidth=n*(menuBar ? 0.06 : 0.042);frame.stroke()
    let stand=NSBezierPath();stand.move(to:NSPoint(x:n*0.5,y:n*0.30));stand.line(to:NSPoint(x:n*0.5,y:n*0.22));stand.move(to:NSPoint(x:n*0.36,y:n*0.22));stand.line(to:NSPoint(x:n*0.64,y:n*0.22));stand.lineWidth=n*(menuBar ? 0.055 : 0.04);stand.lineCapStyle = .round;stand.stroke()
    NSColor.white.setStroke()
    let arrows=NSBezierPath();arrows.lineWidth=n*(menuBar ? 0.045 : 0.03);arrows.lineCapStyle = .round;arrows.lineJoinStyle = .round
    arrows.move(to:NSPoint(x:n*0.32,y:n*0.59));arrows.line(to:NSPoint(x:n*0.68,y:n*0.59));arrows.line(to:NSPoint(x:n*0.61,y:n*0.65));arrows.move(to:NSPoint(x:n*0.68,y:n*0.59));arrows.line(to:NSPoint(x:n*0.61,y:n*0.53))
    arrows.move(to:NSPoint(x:n*0.68,y:n*0.44));arrows.line(to:NSPoint(x:n*0.32,y:n*0.44));arrows.line(to:NSPoint(x:n*0.39,y:n*0.50));arrows.move(to:NSPoint(x:n*0.32,y:n*0.44));arrows.line(to:NSPoint(x:n*0.39,y:n*0.38));arrows.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // Preserve the RGBA layout and alpha. AppKit's gray conversion can corrupt
    // PNG output when its representation uses a different sample layout.
    precondition(rep.bitsPerSample == 8 && rep.samplesPerPixel == 4 && !rep.isPlanar)
    let pixels = rep.bitmapData!
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let offset = y * rep.bytesPerRow + x * 4
            let gray = UInt8((Int(pixels[offset]) + Int(pixels[offset+1]) + Int(pixels[offset+2])) / 3)
            pixels[offset] = gray; pixels[offset+1] = gray; pixels[offset+2] = gray
        }
    }
    let data=rep.representation(using:.png,properties:[:])!
    let names: [String]
    switch size {
    case 16:names=["icon_16x16.png"]
    case 32:names=["icon_16x16@2x.png","icon_32x32.png"]
    case 64:names=["icon_32x32@2x.png"]
    case 128:names=["icon_128x128.png"]
    case 256:names=["icon_128x128@2x.png","icon_256x256.png"]
    case 512:names=["icon_256x256@2x.png","icon_512x512.png"]
    default:names=["icon_512x512@2x.png"]
    }
    for name in names {try data.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name))}
}

// Package the same PNG representations for Windows; never redraw a second icon.
if CommandLine.arguments.count > 2 {
    let sizes = [16, 32, 64, 128, 256]
    let files = ["icon_16x16.png", "icon_32x32.png", "icon_32x32@2x.png", "icon_128x128.png", "icon_256x256.png"]
    let payloads = try files.map { try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent($0)) }
    var ico = Data()
    func appendLE(_ value: Int, _ bytes: Int) {
        for shift in 0..<bytes { ico.append(UInt8((value >> (shift * 8)) & 255)) }
    }
    appendLE(0,2); appendLE(1,2); appendLE(sizes.count,2)
    var offset = 6 + sizes.count * 16
    for i in 0..<sizes.count {
        appendLE(sizes[i] % 256,1); appendLE(sizes[i] % 256,1)
        appendLE(0,1); appendLE(0,1); appendLE(1,2); appendLE(32,2)
        appendLE(payloads[i].count,4); appendLE(offset,4)
        offset += payloads[i].count
    }
    for data in payloads { ico.append(data) }
    try ico.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
