if (!window.planTimelineInitialized) {
  window.planTimelineInitialized = true;

  document.addEventListener('turbo:load', function() {
    const container = document.getElementById('plan-timeline');
    if (!container) return;
    const daysWrapper = container.querySelector('.days');
    const monthLeft = container.querySelector('.month-left');
    const monthRight = container.querySelector('.month-right');
    const navLeft = container.querySelector('.nav-left');
    const navRight = container.querySelector('.nav-right');
    const DAY_WIDTH = 80;

    function formatDate(d) {
      return d.toISOString().slice(0,10);
    }
    function addDays(d, n) {
      const nd = new Date(d);
      nd.setDate(nd.getDate() + n);
      return nd;
    }

    function loadRange(start, end, prepend=false) {
      fetch(`/plans.json?start=${formatDate(start)}&end=${formatDate(end)}`)
        .then(r => r.json())
        .then(data => {
          const fragment = document.createDocumentFragment();
          for (let d = new Date(start); d <= end; d = addDays(d, 1)) {
            const iso = formatDate(d);
            const div = document.createElement('div');
            div.className = 'day';
            div.dataset.date = iso;
            div.style.width = DAY_WIDTH + 'px';
            div.innerHTML = `<div class='day-num'>${('0'+d.getDate()).slice(-2)}</div>`;
            const plans = data[iso] || [];
            if (plans.length) {
              div.classList.add('has-plan');
              const list = document.createElement('div');
              plans.forEach(name => {
                const item = document.createElement('div');
                item.textContent = name;
                list.appendChild(item);
              });
              div.appendChild(list);
            }
            if (prepend) {
              fragment.prepend(div);
            } else {
              fragment.appendChild(div);
            }
          }
          if (prepend) {
            daysWrapper.prepend(fragment);
            container.scrollLeft += (Math.ceil((end-start)/86400000)+1) * DAY_WIDTH;
          } else {
            daysWrapper.appendChild(fragment);
          }
          updateMonths();
        });
    }

    function updateMonths() {
      const rect = container.getBoundingClientRect();
      let first = null, last = null;
      daysWrapper.querySelectorAll('.day').forEach(el => {
        const r = el.getBoundingClientRect();
        if (r.right >= rect.left && first === null) first = el.dataset.date;
        if (r.left <= rect.right) last = el.dataset.date;
      });
      if (first) monthLeft.textContent = first.slice(0,7);
      if (last) monthRight.textContent = last.slice(0,7);
    }

    navLeft.addEventListener('click', function() {
      container.scrollBy({left: -7 * DAY_WIDTH, behavior: 'smooth'});
    });

    navRight.addEventListener('click', function() {
      container.scrollBy({left: 7 * DAY_WIDTH, behavior: 'smooth'});
    });

    container.addEventListener('scroll', function() {
      updateMonths();
      if (container.scrollLeft < 50) {
        const firstDate = new Date(daysWrapper.firstElementChild.dataset.date);
        const s = addDays(firstDate, -30);
        const e = addDays(firstDate, -1);
        loadRange(s, e, true);
      }
      if (container.scrollWidth - container.clientWidth - container.scrollLeft < 50) {
        const lastDate = new Date(daysWrapper.lastElementChild.dataset.date);
        const s = addDays(lastDate, 1);
        const e = addDays(lastDate, 30);
        loadRange(s, e, false);
      }
    });

    const start = addDays(new Date(), -15);
    const end = addDays(new Date(), 15);
    loadRange(start, end, false);
  });
}
