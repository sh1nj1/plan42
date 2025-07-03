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
    var startDate = new Date(container.dataset.startDate || new Date());
    var endDate = new Date(container.dataset.endDate || new Date());

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
        el.dataset.path = plan.path;
        el.dataset.id = plan.id;
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

        if (plan.deletable) {
          var del = document.createElement('button');
          del.type = 'button';
          del.textContent = '×';
          del.className = 'delete-plan-btn';
          el.appendChild(del);
          del.addEventListener('click', function(e) {
            e.stopPropagation();
            if (!confirm(container.dataset.deleteConfirm)) return;
            fetch('/plans/' + plan.id, {
              method: 'DELETE',
              headers: {
                'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content,
                Accept: 'application/json'
              }
            }).then(function(r) {
              if (r.ok) {
                var idx = planEls.findIndex(function(item) { return item.plan.id === plan.id; });
                if (idx > -1) {
                  planEls[idx].el.remove();
                  planEls.splice(idx, 1);
                }
                plans = plans.filter(function(p) { return p.id !== plan.id; });
                updatePlanPositions();
              } else {
                window.location.reload();
              }
            });
          });
        }

        el.addEventListener('click', function() {
          if (plan.path) {
            window.location.href = plan.path;
          }
        });

        scroll.appendChild(el);
        planEls.push({ el: el, plan: plan });
      });
    }

    function updatePlanPositions() {
      var visibleWidth = dayDiff(endDate, startDate) * dayWidth;
      planEls.forEach(function(item, idx) {
        var plan = item.plan;
        var left = dayDiff(plan.created_at, startDate) * dayWidth;
        var width = (dayDiff(plan.target_date, plan.created_at) + 1) * dayWidth;
        var right = left + width;

        if (right < 0 || left > visibleWidth) {
          item.el.style.display = 'none';
          return;
        }

        item.el.style.display = '';
        item.el.style.left = left + 'px';
        item.el.style.top = (idx * rowHeight + 40) + 'px';
        item.el.style.width = width + 'px';

        var label = item.el.querySelector('.plan-label');
        var viewLeft = container.scrollLeft;
        var labelLeft = Math.max(viewLeft, left) - left + 2;
        label.style.left = labelLeft + 'px';
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
      updatePlanPositions();
    }

    renderDays(startDate, endDate, false);
    renderPlans();
    updatePlanPositions();

    function ensureDateVisible(date) {
      if (date < startDate) {
        extendLeft(dayDiff(startDate, date));
      } else if (date > endDate) {
        extendRight(dayDiff(date, endDate));
      }
    }

    function scrollToDate(date) {
      ensureDateVisible(date);
      var offset = dayDiff(date, startDate) * dayWidth - container.clientWidth / 2 + dayWidth / 2;
      container.scrollLeft = offset;
      updatePlanPositions();
    }

    var todayBtn = document.getElementById('timeline-today-btn');
    if (todayBtn) {
      todayBtn.addEventListener('click', function() { scrollToDate(new Date()); });
    }

    scrollToDate(new Date());

    container.addEventListener('scroll', function() {
      if (container.scrollLeft < 50) {
        extendLeft(30);
      }
      if (container.scrollLeft + container.clientWidth > scroll.scrollWidth - 50) {
        extendRight(30);
      }
      updatePlanPositions();
    });
  });
}
