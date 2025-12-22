import { Controller } from "@hotwired/stimulus"
import { get, create, supported } from "@github/webauthn-json"

export default class extends Controller {
    static targets = ["nickname"]
    static values = {
        callbackUrl: String,
        notSupportedMessage: String
    }
    connect() {
        if (this.hasNicknameTarget && !this.nicknameTarget.value) {
            this.nicknameTarget.value = this.generateDefaultNickname()
        }
    }

    generateDefaultNickname() {
        const ua = navigator.userAgent
        let os = "Device"
        if (ua.indexOf("Win") !== -1) os = "Windows"
        if (ua.indexOf("Mac") !== -1) os = "macOS"
        if (ua.indexOf("Linux") !== -1) os = "Linux"
        if (ua.indexOf("Android") !== -1) os = "Android"
        if (ua.indexOf("like Mac") !== -1) os = "iOS"

        let browser = "Browser"
        if (ua.indexOf("Chrome") !== -1) browser = "Chrome"
        else if (ua.indexOf("Safari") !== -1) browser = "Safari"
        else if (ua.indexOf("Firefox") !== -1) browser = "Firefox"
        else if (ua.indexOf("Edg") !== -1) browser = "Edge"

        return `${browser} on ${os}`
    }

    async register(event) {
        if (event) event.preventDefault()

        if (!supported()) {
            alert(this.notSupportedMessageValue)
            return
        }
        const nickname = this.nicknameTarget.value

        try {
            const optionsResponse = await fetch("/webauthn/registration/new", {
                headers: {
                    "Accept": "application/json"
                }
            })
            const options = await optionsResponse.json()

            const credential = await create({ publicKey: options })

            const response = await fetch("/webauthn/registration", {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "X-CSRF-Token": document.querySelector("meta[name='csrf-token']").content
                },
                body: JSON.stringify({ ...credential, nickname })
            })

            if (response.ok) {
                window.location.reload()
            } else {
                const error = await response.json()
                alert(error.message || "Registration failed")
            }
        } catch (error) {
            console.error(error)
            alert("Registration failed. See console for details.")
        }
    }

    async signin() {
        if (!supported()) {
            alert(this.notSupportedMessageValue)
            return
        }
        try {
            const optionsResponse = await fetch("/webauthn/session/new", {
                headers: {
                    "Accept": "application/json"
                }
            })
            const options = await optionsResponse.json()

            const credential = await get({ publicKey: options })

            const response = await fetch("/webauthn/session", {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "X-CSRF-Token": document.querySelector("meta[name='csrf-token']").content
                },
                body: JSON.stringify(credential)
            })

            const data = await response.json()
            if (response.ok) {
                window.location.href = data.redirect_url
            } else {
                alert(data.message || "Sign in failed")
            }
        } catch (error) {
            console.error(error)
            alert("Sign in failed. See console for details.")
        }
    }

    delete(event) {
        if (!confirm("Are you sure you want to delete this passkey?")) {
            event.preventDefault()
        }
    }
}
