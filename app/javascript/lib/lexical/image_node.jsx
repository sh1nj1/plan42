import {
    $applyNodeReplacement,
    createEditor,
    DecoratorNode,
} from "lexical"

export class ImageNode extends DecoratorNode {
    __src
    __altText
    __width
    __height
    __maxWidth

    static getType() {
        return "image"
    }

    static clone(node) {
        return new ImageNode(
            node.__src,
            node.__altText,
            node.__maxWidth,
            node.__width,
            node.__height,
            node.__key
        )
    }

    static importJSON(serializedNode) {
        const { altText, height, width, maxWidth, src } = serializedNode
        const node = $createImageNode({
            altText,
            height,
            maxWidth,
            src,
            width,
        })
        return node
    }

    exportDOM() {
        const element = document.createElement("img")
        element.setAttribute("src", this.__src)
        element.setAttribute("alt", this.__altText)
        if (this.__width) {
            element.setAttribute("width", this.__width.toString())
        }
        if (this.__height) {
            element.setAttribute("height", this.__height.toString())
        }
        return { element }
    }

    static importDOM() {
        return {
            img: (node) => ({
                conversion: convertImageElement,
                priority: 0,
            }),
        }
    }

    constructor(src, altText, maxWidth, width, height, key) {
        super(key)
        this.__src = src
        this.__altText = altText
        this.__maxWidth = maxWidth
        this.__width = width || "inherit"
        this.__height = height || "inherit"
    }

    exportJSON() {
        return {
            altText: this.getAltText(),
            height: this.__height === "inherit" ? 0 : this.__height,
            maxWidth: this.__maxWidth,
            src: this.getSrc(),
            type: "image",
            version: 1,
            width: this.__width === "inherit" ? 0 : this.__width,
        }
    }

    setWidthAndHeight(width, height) {
        const writable = this.getWritable()
        writable.__width = width
        writable.__height = height
    }

    createDOM(config) {
        const span = document.createElement("span")
        const theme = config.theme
        const className = theme.image
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

    getAltText() {
        return this.__altText
    }

    decorate() {
        const handleClick = (e) => {
            // Stop propagation to prevent creative-row navigation
            e.stopPropagation()
        }

        return (
            <img
                src={this.__src}
                alt={this.__altText}
                onClick={handleClick}
                style={{
                    width: this.__width === "inherit" ? "100%" : this.__width,
                    height: this.__height === "inherit" ? "auto" : this.__height,
                    maxWidth: this.__maxWidth,
                    cursor: "default",
                }}
            />
        )
    }
}

function convertImageElement(domNode) {
    if (domNode instanceof HTMLImageElement) {
        const { alt: altText, src, width, height } = domNode
        const node = $createImageNode({ altText, height, src, width })
        return { node }
    }
    return null
}

export function $createImageNode({
    altText,
    height,
    maxWidth = 500,
    src,
    width,
}) {
    return $applyNodeReplacement(
        new ImageNode(src, altText, maxWidth, width, height)
    )
}

export function $isImageNode(node) {
    return node instanceof ImageNode
}
