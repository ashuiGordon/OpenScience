import PDFKit
import SwiftUI

/// Renders one PDF page into an inert bitmap. PDF annotations, URI actions, JavaScript, Launch
/// actions, forms, and embedded content never receive an interactive PDFKit surface.
struct WorkbenchPDFPreview: View {
    let artifactID: String
    let data: Data
    let fillsViewport: Bool

    private let pageImage: NSImage?
    private let pageCount: Int

    init(artifactID: String, data: Data, fillsViewport: Bool = false) {
        self.artifactID = artifactID
        self.data = data
        self.fillsViewport = fillsViewport
        let document = PDFDocument(data: data)
        pageCount = document?.pageCount ?? 0
        pageImage = document?.page(at: 0)?.thumbnail(
            of: NSSize(width: 1_020, height: 1_320),
            for: .cropBox
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pageImage {
                if fillsViewport {
                    Image(nsImage: pageImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .accessibilityLabel("PDF 第 1 页静态预览")
                        .background(Color.white)
                } else {
                    Image(nsImage: pageImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("PDF 第 1 页静态预览")
                        .background(Color.white)
                }
            } else {
                ContentUnavailableView(
                    "无法渲染 PDF",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("文件保持只读，未加载任何交互内容。")
                )
            }
            Text(pageCount > 0 ? "第 1 页，共 \(pageCount) 页 · 静态只读预览" : "静态只读预览")
                .font(.caption2)
                .foregroundStyle(WorkbenchTheme.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("只读 PDF 研究产物预览：\(artifactID)")
        .accessibilityHint("预览是静态图像，不会执行链接、脚本、表单或嵌入指令。")
    }
}
