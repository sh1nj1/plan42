import React, { useState, useEffect, useRef } from "react"

export default function LinkPopup({ initialLabel, initialUrl, onConfirm, onCancel }) {
    const [label, setLabel] = useState(initialLabel || "")
    const [url, setUrl] = useState(initialUrl || "")
    const popupRef = useRef(null)

    useEffect(() => {
        setLabel(initialLabel || "")
        setUrl(initialUrl || "")
    }, [initialLabel, initialUrl])

    useEffect(() => {
        const handleClickOutside = (event) => {
            if (popupRef.current && !popupRef.current.contains(event.target)) {
                onCancel()
            }
        }
        document.addEventListener("mousedown", handleClickOutside)
        return () => {
            document.removeEventListener("mousedown", handleClickOutside)
        }
    }, [onCancel])

    const handleSubmit = (e) => {
        e.preventDefault()
        onConfirm(label, url)
    }

    const handleKeyDown = (e) => {
        if (e.key === "Escape") {
            e.preventDefault()
            e.stopPropagation()
            onCancel()
        }
    }

    return (
        <div
            ref={popupRef}
            className="lexical-link-popup stacked-form"
            style={{
                position: "absolute",
                top: "40px",
                right: "0",
                zIndex: 100,
                backgroundColor: "var(--color-bg)",
                padding: "1rem",
                borderRadius: "8px",
                boxShadow: "0 4px 12px rgba(0,0,0,0.15)",
                border: "1px solid var(--color-border)",
                minWidth: "260px"
            }}>
            <button
                type="button"
                onClick={onCancel}
                style={{
                    position: "absolute",
                    top: "8px",
                    right: "8px",
                    background: "none",
                    border: "none",
                    cursor: "pointer",
                    color: "var(--color-muted, #999)",
                    fontSize: "1.2rem",
                    lineHeight: 1,
                    padding: "0 4px"
                }}
                title="Close">
                ×
            </button>
            <form onSubmit={handleSubmit}>
                <div>
                    <input
                        type="text"
                        placeholder="Link text"
                        value={label}
                        onChange={(e) => setLabel(e.target.value)}
                        onKeyDown={handleKeyDown}
                        style={{ width: "100%", boxSizing: "border-box", marginBottom: "0.5rem" }}
                    />
                </div>
                <div>
                    <input
                        type="text"
                        placeholder="https://example.com"
                        value={url}
                        onChange={(e) => setUrl(e.target.value)}
                        onKeyDown={handleKeyDown}
                        style={{ width: "100%", boxSizing: "border-box" }}
                    />
                </div>
                <div style={{ display: "flex", justifyContent: "flex-end", marginTop: "0.5rem" }}>
                    <button
                        type="submit"
                        className="primary-action-button"
                        title="Confirm"
                        style={{ display: "flex", alignItems: "center", justifyContent: "center", padding: "0.45em 0.6em" }}>
                        <svg
                            xmlns="http://www.w3.org/2000/svg"
                            width="16"
                            height="16"
                            fill="currentColor"
                            viewBox="0 0 16 16">
                            <path d="M13.854 3.646a.5.5 0 0 1 0 .708l-7 7a.5.5 0 0 1-.708 0l-3.5-3.5a.5.5 0 1 1 .708-.708L6.5 10.293l6.646-6.647a.5.5 0 0 1 .708 0z" />
                        </svg>
                    </button>
                </div>
            </form>
        </div>
    )
}
