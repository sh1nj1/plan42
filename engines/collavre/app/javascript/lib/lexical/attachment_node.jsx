import { createElement } from "react"
import { attachmentLinkLabel, attachmentLinkParts } from "./attachment_presentation"

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
        return createElement("a", {
            href: this.__src,
            download: this.__filename,
            className: "attachment-link",
            "aria-label": attachmentLinkLabel(this.__filename, this.__filesize),
            onClick: (event) => event.stopPropagation(),
        }, ...attachmentLinkParts(this.__filename, this.__filesize).map(({className, text, sizeLabel}, index) =>
            createElement("span", {className, key: index, "data-filesize-label": sizeLabel}, text)
        ))
    }
}

function convertAttachmentElement(domNode) {
    if (domNode instanceof HTMLAnchorElement && domNode.hasAttribute("download")) {
        const src = domNode.getAttribute("href")
        const filename = domNode.getAttribute("download") ||
            domNode.querySelector(".attachment-link-name")?.textContent || domNode.textContent
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
