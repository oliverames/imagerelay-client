import Testing
@testable import ImageRelayKit

@Suite("FilenamePresentation")
struct FilenamePresentationTests {
    @Test("serverCanonical returns input unchanged")
    func canonicalIdentity() {
        let names = [
            "annual-report.pdf",
            "design-doc-v2.docx",
            "image.png",
            "",
            "no-extension",
            ".hidden",
            "weird---multi-dash.txt"
        ]
        for name in names {
            #expect(FilenamePresentation.display(name, style: .serverCanonical) == name)
        }
    }

    @Test("humanReadable replaces dashes with spaces and title-cases")
    func basicTransform() {
        #expect(FilenamePresentation.display("annual-report.pdf", style: .humanReadable)
                == "Annual Report.pdf")
    }

    @Test("multi-word filenames title-case each token")
    func multiToken() {
        #expect(FilenamePresentation.display("q3-marketing-deck-final.key", style: .humanReadable)
                == "Q3 Marketing Deck Final.key")
    }

    @Test("words with existing uppercase pass through while siblings still title-case")
    func preservesAcronyms() {
        #expect(FilenamePresentation.display("API-spec.md", style: .humanReadable)
                == "API Spec.md")
        #expect(FilenamePresentation.display("iPhone-photos.zip", style: .humanReadable)
                == "iPhone Photos.zip")
    }

    @Test("no dashes still title-cases the base name")
    func singleWord() {
        #expect(FilenamePresentation.display("readme.txt", style: .humanReadable)
                == "Readme.txt")
    }

    @Test("no extension is handled cleanly")
    func noExtension() {
        #expect(FilenamePresentation.display("design-doc", style: .humanReadable)
                == "Design Doc")
    }

    @Test("empty input is preserved")
    func emptyInput() {
        #expect(FilenamePresentation.display("", style: .humanReadable) == "")
    }

    @Test("dot-files are left alone")
    func dotFiles() {
        #expect(FilenamePresentation.display(".gitignore", style: .humanReadable)
                == ".gitignore")
        #expect(FilenamePresentation.display(".env-local", style: .humanReadable)
                == ".env-local")
    }

    @Test("collapsed multi-dashes don't produce empty tokens")
    func multiDashCollapse() {
        #expect(FilenamePresentation.display("foo---bar.pdf", style: .humanReadable)
                == "Foo Bar.pdf")
    }

    @Test("version-like tokens are title-cased")
    func versionTokens() {
        #expect(FilenamePresentation.display("release-v1.2.pdf", style: .humanReadable)
                == "Release V1.2.pdf")
    }

    @Test("default parameter is .serverCanonical")
    func defaultStyle() {
        #expect(FilenamePresentation.display("annual-report.pdf")
                == "annual-report.pdf")
    }
}
