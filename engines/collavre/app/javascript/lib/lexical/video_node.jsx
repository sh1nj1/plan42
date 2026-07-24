import {
    $applyNodeReplacement,
    DecoratorNode,
} from "lexical"

export class VideoNode extends DecoratorNode {
    __src
    __filename

    static getType() {
        return "video"
    }

    static clone(node) {
        return new VideoNode(node.__src, node.__filename, node.__key)
    }

    static importJSON(serializedNode) {
        const { src, filename } = serializedNode
        return $createVideoNode({ src, filename })
    }

    exportDOM() {
        const element = document.createElement("video")
        element.setAttribute("src", this.__src)
        element.setAttribute("controls", "")
        return { element }
    }

    static importDOM() {
        return {
            video: () => ({ conversion: convertVideoElement, priority: 1 }),
        }
    }

    constructor(src, filename, key) {
        super(key)
        this.__src = src
        this.__filename = filename
    }

    exportJSON() {
        return {
            src: this.getSrc(),
            filename: this.__filename,
            type: "video",
            version: 1,
        }
    }

    createDOM(config) {
        const span = document.createElement("span")
        const className = config.theme?.video
        if (className !== undefined) span.className = className
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
        return (
            <video
                src={this.__src}
                controls
                style={{ maxWidth: "100%", borderRadius: "4px" }}
            />
        )
    }
}

function convertVideoElement(domNode) {
    if (domNode instanceof HTMLVideoElement) {
        const src = domNode.getAttribute("src")
        if (!src) return null
        return { node: $createVideoNode({ src, filename: null }) }
    }
    return null
}

export function $createVideoNode({ src, filename }) {
    return $applyNodeReplacement(new VideoNode(src, filename))
}

export function $isVideoNode(node) {
    return node instanceof VideoNode
}
