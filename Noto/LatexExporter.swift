//
//  LatexExpoerter.swift
//  NTex
//
//  Created by Wataru Ishihara on 9/10/25.
//

import Foundation

struct LatexExporter {
    static func buildTeXDocument(body: String, title: String = "Noto Document") -> String {
        """
        \\documentclass[11pt]{article}
        \\usepackage[utf8]{inputenc}
        \\usepackage{amsmath, amssymb, amsfonts}
        \\usepackage[margin=1in]{geometry}
        \\usepackage{graphicx}
        \\usepackage{hyperref}
        
        \\title{\(title)}
        \\author{Noto}
        \\date{\\today}
        
        \\begin{document}
        \\maketitle
        
        \(body)
        
        \\end{document}
        """
    }

    static func writeTeXFile(body: String, fileName: String = "Noto-Document.tex") throws -> URL {
        let tex = buildTeXDocument(body: body)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try tex.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }
}
