import XCTest
import CoreImage
@testable import PGYDepthDemo

final class PortraitImagingTests: XCTestCase {
    private let context = CIContext()
    private func scene(checker: Bool = true, separatedDepth: Bool = false, touching: Bool = false, edgePerson: Bool = false) throws -> (CGImage, PortraitAnalysis, DepthField) {
        let side = 256
        var rgba = [UInt8](repeating: 0, count:side*side*4)
        var a = [UInt8](repeating:0,count:side*side), b = a, labels = a
        var depth = [Float](repeating:0.15,count:side*side)
        for y in 0..<side { for x in 0..<side {
            let i=y*side+x; rgba[i*4+2]=255; rgba[i*4+3]=255
            let id:UInt8 = (32..<(touching ? 108 : 112)).contains(x) && (40..<216).contains(y) ? 1 : (((edgePerson ? 224 : (touching ? 108 : 128))..<(edgePerson ? 256 : 208)).contains(x) && (40..<216).contains(y) ? 2 : 0)
            if id > 0 {
                labels[i]=id
                if id == 1 { a[i]=255 } else { b[i]=255 }
                let color:UInt8 = checker ? (((x/2+y/2)%2 == 0) ? 20 : 240) : 255
                rgba[i*4]=id == 1 ? color : 0; rgba[i*4+1]=id == 2 ? color : 0; rgba[i*4+2]=0
                depth[i] = separatedDepth ? (id == 1 ? 0.25 : 0.85) : 0.5
            }
        } }
        let image = CIImage(bitmapData:Data(rgba),bytesPerRow:side*4,size:.init(width:side,height:side),format:.RGBA8,colorSpace:ImageSupport.colorSpace)
        let segmentation = try SubjectSegmentation(labels:.init(width:side,height:side,bytes:Data(labels)), subjects:[
            .init(id:1,mask:.init(width:side,height:side,bytes:Data(a))),.init(id:2,mask:.init(width:side,height:side,bytes:Data(b)))])
        let people = try PortraitAnalysis(segmentation:segmentation,sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:side,height:side))
        return (try ImageSupport.cgImage(image,context:context),people,try .init(width:side,height:side,values:depth))
    }
    private func pixels(_ image:CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        context.render(CIImage(cgImage:image),toBitmap:&bytes,rowBytes:image.width*4,bounds:.init(x:0,y:0,width:image.width,height:image.height),format:.RGBA8,colorSpace:ImageSupport.colorSpace)
        return bytes
    }
    private func draw(_ source:CGImage,_ people:PortraitAnalysis,_ depth:DepthField,id:UInt8,enabled:Bool=true,renderer:DepthRenderer?=nil,photoID:UUID=UUID()) throws -> CGImage {
        var r=EditRecipe();r.selectedPersonID=id;r.aperture=1.4;r.depthEnabled=enabled;r.focusPoint=people.anchor(for:id) ?? .center
        return try (renderer ?? DepthRenderer(context:context)).render(image:source,photoID:photoID,analysis:.native(depth),sourceSize:people.imageSize,recipe:r,portrait:people)
    }
    private func detail(_ bytes:[UInt8],x:Int,channel:Int) -> Int {
        (70..<185).reduce(0) { $0 + abs(Int(bytes[($1*256+x)*4+channel])-Int(bytes[(($1+1)*256+x)*4+channel])) }
    }
    func testSameDepthPeopleSwitchWithoutReusingOldPersonCache() throws {
        let (source,people,depth)=try scene(),renderer=DepthRenderer(context:context),id=UUID()
        let original=pixels(source)
        let first=pixels(try draw(source,people,depth,id:1,renderer:renderer,photoID:id))
        let second=pixels(try draw(source,people,depth,id:2,renderer:renderer,photoID:id))
        XCTAssertEqual(detail(first,x:70,channel:0),detail(original,x:70,channel:0))
        XCTAssertLessThan(detail(first,x:165,channel:1),detail(original,x:165,channel:1)/2)
        XCTAssertEqual(detail(second,x:165,channel:1),detail(original,x:165,channel:1))
        XCTAssertLessThan(detail(second,x:70,channel:0),detail(original,x:70,channel:0)/2)
    }
    func testSelectedPersonDoesNotBleedColorIntoAdjacentBackground() throws {
        let (source,people,depth)=try scene(checker:false)
        let image=try draw(source,people,depth,id:1),bytes=pixels(image)
        XCTAssertLessThan(bytes[(128*256+29)*4],8,"蓝色背景不应混入清晰人物的红色")
        XCTAssertGreaterThan(bytes[(128*256+40)*4],245)
        let attachment=XCTAttachment(data:try ImageSupport.jpegData(image),uniformTypeIdentifier:"public.jpeg")
        attachment.name="portrait-edge-no-red-halo";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testDefocusedForegroundSpreadsOverBackgroundWithoutSharpGhost() throws {
        let (source,people,depth)=try scene(checker:false,separatedDepth:true)
        let image=try draw(source,people,depth,id:1),bytes=pixels(image)
        XCTAssertGreaterThan(bytes[(128*256+125)*4+1],8,"前景绿色人物虚化应扩散到轮廓之外")
        XCTAssertLessThan(bytes[(128*256+127)*4+1],250,"旧轮廓不能残留清晰硬边")
    }
    func testBlurredForegroundStillOccludesSelectedBackPerson() throws {
        let (source,people,depth) = try scene(checker:false,separatedDepth:true,touching:true)
        let bytes = pixels(try draw(source,people,depth,id:1))
        XCTAssertGreaterThan(bytes[(128*256+105)*4+1],30,"前景虚化要扩散遮挡后方清晰人物，不能最后强行贴回主体")
        XCTAssertGreaterThan(bytes[(128*256+70)*4],245)
    }
    func testSoftMatteAndTopLeftOrientationSurviveCompositing() throws {
        let width = 64, height = 96
        var data = [UInt8](repeating:0,count:width*height*4)
        var mask = [UInt8](repeating:0,count:width*height)
        for y in 0..<height { for x in 0..<width {
            let index = y*width+x
            let alpha:UInt8 = (8..<35).contains(y) && (12..<48).contains(x) ? (x == 12 ? 128 : 255) : 0
            mask[index] = alpha
            data[index*4] = alpha == 128 ? 188 : alpha
            data[index*4+2] = alpha == 128 ? 187 : 255-alpha; data[index*4+3] = 255
        } }
        let provider = try XCTUnwrap(CGDataProvider(data:Data(data) as CFData))
        let source = try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:width*4,space:ImageSupport.colorSpace,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
        let soft = try GrayMask(width:width,height:height,bytes:Data(mask))
        let people = try PortraitAnalysis(segmentation: .init(labels:.init(width:width,height:height,bytes:Data(mask.map { $0 > 0 ? 1 : 0 })),
            subjects:[.init(id:1,mask:soft)]),sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:width,height:height))
        let depth = try DepthField(width:width,height:height,values:mask.map { $0 > 0 ? 0.8 : 0.2 })
        let rendered = try draw(source,people,depth,id:1)
        let output = pixels(rendered), original = pixels(source)
        for (name,image) in [("asymmetric-source",source),("asymmetric-render",rendered)] {
            let attachment = XCTAttachment(data:try ImageSupport.jpegData(image),uniformTypeIdentifier:"public.jpeg")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        print("[MatteRows] source top=\(original[(20*width+25)*4]) bottom=\(original[(75*width+25)*4]); output top=\(output[(20*width+25)*4]) bottom=\(output[(75*width+25)*4])")
        // CI render(toBitmap:) and GrayMask both use top-left row order.
        let row = 20
        XCTAssertEqual(original[(row*width+25)*4],255)
        XCTAssertEqual(output[(row*width+25)*4],original[(row*width+25)*4])
        XCTAssertLessThan(output[((height-1-20)*width+25)*4],8,"人物不能上下颠倒")
        let edge = output[(row*width+12)*4]
        XCTAssertEqual(Int(edge),Int(original[(row*width+12)*4]),accuracy:2,"半透明红边应保持原始亮度")
        XCTAssertEqual(Int(output[(row*width+12)*4+2]),Int(original[(row*width+12)*4+2]),accuracy:2,"蓝色衬底应正确重建")
    }
    func testDefocusedPersonAtFrameEdgeStaysOpaque() throws {
        let (source,people,depth) = try scene(checker:false,edgePerson:true)
        let bytes = pixels(try draw(source,people,depth,id:1))
        XCTAssertGreaterThan(bytes[(128*256+255)*4+1],250)
        XCTAssertLessThan(bytes[(128*256+255)*4+2],5,"画面外透明像素不能侵蚀贴边人物")
        let (textured,texturePeople,textureDepth) = try scene(edgePerson:true)
        let blurred = pixels(try draw(textured,texturePeople,textureDepth,id:1))
        XCTAssertLessThan(detail(blurred,x:255,channel:1),detail(pixels(textured),x:255,channel:1)/20,
            "贴边失焦人物不能露出底层原始清晰纹理")
    }
    func testDisablingPortraitEffectKeepsPixels() throws {
        let (source,people,depth)=try scene()
        XCTAssertEqual(pixels(try draw(source,people,depth,id:1,enabled:false)),pixels(source))
    }
}
