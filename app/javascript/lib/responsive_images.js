export function updateResponsiveImages(container) {
    if (!container) return

    const images = container.querySelectorAll("img")
    const containerWidth = container.clientWidth

    images.forEach((img) => {
        const src = img.getAttribute("src")
        if (!src) return

        // Skip if not an internal image or already processed (optional check)
        // For now, we assume we want to update all images that look like they might support resizing
        // or just append params if the server supports it.
        // Assuming ActiveStorage variants or similar can be requested via params,
        // but standard ActiveStorage URLs are signed and immutable.
        // If we are using a proxy or a service that supports resizing via query params (like Cloudinary or a custom proxy), this works.
        // If using standard ActiveStorage, we might need to request a variant URL from the server.
        // However, the user request said: "dynamically append width/height parameters based on the currently requested size"
        // This implies the image server supports it.

        try {
            const url = new URL(src, window.location.origin)
            // Only update if width changed significantly to avoid thrashing
            const currentW = url.searchParams.get("w")
            const targetW = Math.round(containerWidth)

            if (currentW && Math.abs(Number(currentW) - targetW) < 50) return

            url.searchParams.set("w", targetW)
            // url.searchParams.set("h", ...) // Height is usually auto based on aspect ratio

            // Update src only if changed
            if (url.toString() !== src) {
                img.src = url.toString()
            }
        } catch (e) {
            // Ignore invalid URLs
        }
    })
}

// Observer to watch for resizing
export function observeResponsiveImages(container) {
    if (!container) return null

    const observer = new ResizeObserver(() => {
        updateResponsiveImages(container)
    })

    observer.observe(container)
    return observer
}
