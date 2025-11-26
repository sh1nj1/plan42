import {
    $applyNodeReplacement,
    DecoratorNode,
} from "lexical"

export class AttachmentNode extends DecoratorNode {
    __src
    __filename
    __filesize

    static getType() {
        return "attachment"
    }

    static clone(node) {
        return new AttachmentNode(
            node.__src,
            node.__filename,
            node.__filesize,
            node.__key
        )
    }

    static importJSON(serializedNode) {
        const { src, filename, filesize } = serializedNode
        const node = $createAttachmentNode({
            src,
            filename,
            filesize,
        })
        return node
    }

    exportDOM() {
        const element = document.createElement("a")
        element.setAttribute("href", this.__src)
        element.setAttribute("download", this.__filename)
        element.textContent = this.__filename
        if (this.__filesize) {
            element.setAttribute("data-filesize", this.__filesize.toString())
        }
        return { element }
    }

    static importDOM() {
        return {
            a: (node) => {
                if (node.hasAttribute("download")) {
                    return {
                        conversion: convertAttachmentElement,
                        priority: 1,
                    }
                }
                return null
            },
        }
    }

    constructor(src, filename, filesize, key) {
        super(key)
        this.__src = src
        this.__filename = filename
        this.__filesize = filesize
    }

    exportJSON() {
        return {
            src: this.getSrc(),
            filename: this.getFilename(),
            filesize: this.__filesize,
            type: "attachment",
            version: 1,
        }
    }

    createDOM(config) {
        const span = document.createElement("span")
        const theme = config.theme
        const className = theme.attachment
        if (className !== undefined) {
            span.className = className
        }
        return span
    }

    updateDOM() {
        return false
    }

    getSrc() {
        return this.__src
    }

    getFilename() {
        return this.__filename
    }

    decorate() {
        const formatFileSize = (bytes) => {
            if (!bytes) return ""
            if (bytes < 1024) return `${bytes} B`
            if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
            return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
        }

        const handleClick = (e) => {
            // Stop propagation to prevent creative-row navigation
            e.stopPropagation()
        }

        return (
            <a
                href={this.__src}
                download={this.__filename}
                onClick={handleClick}
                style={{
                    display: "inline-flex",
                    alignItems: "center",
                    gap: "0.5em",
                    padding: "0.5em 0.75em",
                    background: "var(--color-bg)",
                    border: "1px solid var(--color-border)",
                    borderRadius: "4px",
                    textDecoration: "none",
                    color: "var(--color-text)",
                    fontSize: "0.9em",
                }}
            >
                <span style={{ fontSize: "1.2em" }}>📎</span>
                <span>{this.__filename}</span>
                {this.__filesize && (
                    <span style={{ color: "var(--color-muted)", fontSize: "0.85em" }}>
                        ({formatFileSize(this.__filesize)})
                    </span>
                )}
            </a>
        )
    }
}

function convertAttachmentElement(domNode) {
    if (domNode instanceof HTMLAnchorElement && domNode.hasAttribute("download")) {
        const src = domNode.getAttribute("href")
        const filename = domNode.getAttribute("download") || domNode.textContent
        const filesize = domNode.getAttribute("data-filesize")
        const node = $createAttachmentNode({
            src,
            filename,
            filesize: filesize ? parseInt(filesize) : null
        })
        return { node }
    }
    return null
}

export function $createAttachmentNode({
    src,
    filename,
    filesize,
}) {
    return $applyNodeReplacement(
        new AttachmentNode(src, filename, filesize)
    )
}

export function $isAttachmentNode(node) {
    return node instanceof AttachmentNode
}
