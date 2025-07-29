if (!window.plansTimelineScriptInitialized) {
  window.plansTimelineScriptInitialized = true;

  function initPlansTimeline(container) {
    if (!container || container.dataset.initialized) return;
    container.dataset.initialized = 'true';

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
    container.dataset.lastLoadedDate = new Date().toISOString().slice(0, 10);

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

    function createPlanBar(plan, idx) {
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

      return el;
    }

    function addPlan(plan) {
      plans.push(plan);
      var el = createPlanBar(plan, planEls.length);
      scroll.appendChild(el);
      planEls.push({ el: el, plan: plan });
      updatePlanPositions();
    }

    function renderPlans() {
      plans.forEach(function(plan, idx) {
        var el = createPlanBar(plan, idx);
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

    function loadPlans(centerDate) {
      var dateStr = centerDate.toISOString().slice(0, 10);
      if (container.dataset.lastLoadedDate === dateStr) return;
      container.dataset.lastLoadedDate = dateStr;
      fetch('/plans.json?date=' + dateStr)
        .then(function(r) { return r.json(); })
        .then(function(newPlans) {
          plans = newPlans.map(function(p) {
            p.created_at = new Date(p.created_at);
            p.target_date = new Date(p.target_date);
            return p;
          });
          planEls.forEach(function(item) { item.el.remove(); });
          planEls = [];
          renderPlans();
          updatePlanPositions();
        });
    }

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

    var scrollTimer;
    container.addEventListener('scroll', function() {
      if (container.scrollLeft < 50) {
        extendLeft(30);
      }
      if (container.scrollLeft + container.clientWidth > scroll.scrollWidth - 50) {
        extendRight(30);
      }
      updatePlanPositions();
      clearTimeout(scrollTimer);
      scrollTimer = setTimeout(function() {
        var centerOffset = container.scrollLeft + container.clientWidth / 2;
        var daysFromStart = centerOffset / dayWidth;
        var centerDate = new Date(startDate.getTime() + Math.round(daysFromStart) * 86400000);
        loadPlans(centerDate);
      }, 200);
    });

    var planForm = document.getElementById('new-plan-form');
    if (planForm) {
      planForm.addEventListener('submit', function(e) {
        e.preventDefault();
        var fd = new FormData(planForm);
        fetch(planForm.action, {
          method: 'POST',
          headers: {
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content,
            Accept: 'application/json'
          },
          body: fd
        }).then(function(r) {
          if (r.ok) return r.json();
          return r.json().then(function(j) { throw j; });
        }).then(function(plan) {
          plan.created_at = new Date(plan.created_at);
          plan.target_date = new Date(plan.target_date);
          addPlan(plan);
          planForm.reset();
        }).catch(function(err) {
          if (err && err.errors) {
            alert(err.errors.join(', '));
          } else {
            window.location.reload();
          }
        });
      });
    }
  }

  window.initPlansTimeline = initPlansTimeline;
}
