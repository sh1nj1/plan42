var Plan42 = (typeof window !== 'undefined') ? (window.Plan42 || (window.Plan42 = {})) : {};

function fallbackCopyText(text) {
    return new Promise(function(resolve, reject) {
        var temp = document.createElement('textarea');
        temp.value = text;
        temp.setAttribute('readonly', '');
        temp.style.position = 'fixed';
        temp.style.opacity = '0';
        temp.style.pointerEvents = 'none';
        document.body.appendChild(temp);
        var succeeded = false;
        try {
            temp.focus();
            temp.select();
            succeeded = document.execCommand('copy');
        } catch (err) {
            succeeded = false;
        }
        document.body.removeChild(temp);
        if (succeeded) {
            resolve();
        } else {
            reject();
        }
    });
}

function copyTextToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        return navigator.clipboard.writeText(text).catch(function() {
            return fallbackCopyText(text);
        });
    }
    return fallbackCopyText(text);
}

Plan42.copyTextToClipboard = copyTextToClipboard;

export { copyTextToClipboard };
