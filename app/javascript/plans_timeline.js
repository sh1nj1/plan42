if (!window.plansTimelineInitialized) {
  window.plansTimelineInitialized = true;

  document.addEventListener('turbo:load', function() {
    var container = document.getElementById('plans-timeline');
    if (!container) return;

    var plans = [];
    try { plans = JSON.parse(container.dataset.plans || '[]'); } catch(e) {}
    plans = plans.map(function(p) {
      p.created_at = new Date(p.created_at);
      p.target_date = new Date(p.target_date);
      return p;
    });

    var dayWidth = 80; // pixels per day
    var rowHeight = 26;
    var startDate = new Date();
    if (plans.length) {
      startDate = plans.reduce(function(min, p) {
        return p.created_at < min ? p.created_at : min;
      }, plans[0].created_at);
    }
    startDate.setDate(startDate.getDate() - 30);
    var endDate = new Date(startDate);
    endDate.setDate(endDate.getDate() + 60);

    var scroll = document.createElement('div');
    scroll.className = 'timeline-scroll';
    container.appendChild(scroll);

    function dayDiff(d1, d2) {
      return Math.round((d1 - d2) / 86400000);
    }

    function createDay(date) {
      var el = document.createElement('div');
      el.className = 'timeline-day';
      el.dataset.date = date.toISOString().slice(0,10);
      el.innerHTML = '<div class="day-label">' + (date.getMonth()+1) + '/' + date.getDate() + '</div>';
      return el;
    }

    function renderDays(from, to, prepend) {
      var date = new Date(from);
      while (date <= to) {
        var el = createDay(new Date(date));
        if (prepend) {
          scroll.insertBefore(el, scroll.firstChild);
        } else {
          scroll.appendChild(el);
        }
        date.setDate(date.getDate() + 1);
      }
    }

    var planEls = [];
    function renderPlans() {
      plans.forEach(function(plan, idx) {
        var el = document.createElement('div');
        el.className = 'plan-bar';
        var left = dayDiff(plan.created_at, startDate) * dayWidth;
        var width = (dayDiff(plan.target_date, plan.created_at) + 1) * dayWidth;
        el.style.left = left + 'px';
        el.style.top = (idx * rowHeight + 40) + 'px';
        el.style.width = width + 'px';

        var prog = document.createElement('div');
        prog.className = 'plan-progress';
        prog.style.width = (plan.progress * 100) + '%';
        el.appendChild(prog);

        var label = document.createElement('span');
        label.className = 'plan-label';
        label.textContent = plan.name + ' ' + Math.round(plan.progress * 100) + '%';
        el.appendChild(label);

        scroll.appendChild(el);
        planEls.push({ el: el, plan: plan });
      });
    }

    function updatePlanPositions() {
      planEls.forEach(function(item, idx) {
        var left = dayDiff(item.plan.created_at, startDate) * dayWidth;
        item.el.style.left = left + 'px';
      });
    }

    function extendLeft(n) {
      startDate.setDate(startDate.getDate() - n);
      renderDays(startDate, new Date(startDate.getTime() + (n-1)*86400000), true);
      updatePlanPositions();
      container.scrollLeft += n * dayWidth;
    }

    function extendRight(n) {
      var from = new Date(endDate.getTime() + 86400000);
      endDate.setDate(endDate.getDate() + n);
      renderDays(from, endDate, false);
    }

    renderDays(startDate, endDate, false);
    renderPlans();

    container.addEventListener('scroll', function() {
      if (container.scrollLeft < 50) {
        extendLeft(30);
      }
      if (container.scrollLeft + container.clientWidth > scroll.scrollWidth - 50) {
        extendRight(30);
      }
    });
  });
}
