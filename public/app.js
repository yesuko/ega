// Ega: small enhancements on top of plain forms. Every page works
// without this; it adds live previews and the add sheet.
(function () {
  'use strict';

  // "1,200.50" -> 120050 pesewas; malformed -> null. Matches Money.parse.
  function parse(raw) {
    var value = String(raw || '').replace(/GH[S₵¢C]|₵|¢|[,\s]/gi, '');
    if (!/^\d+(\.\d{1,2})?$/.test(value)) return null;
    var parts = value.split('.');
    return parseInt(parts[0], 10) * 100 + parseInt(((parts[1] || '') + '00').slice(0, 2), 10);
  }

  // 120050 -> "GH₵ 1,200.50"; short drops ".00". Matches Money.format.
  function cedis(pesewas, short) {
    var sign = pesewas < 0 ? '-' : '';
    var abs = Math.abs(pesewas);
    var whole = Math.floor(abs / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    var fraction = (abs % 100).toString().padStart(2, '0');
    return 'GH₵ ' + sign + whole + (short && fraction === '00' ? '' : '.' + fraction);
  }

  function data(id) {
    var node = document.getElementById(id);
    return node ? JSON.parse(node.textContent) : null;
  }

  function checked(form, name) {
    var input = form.querySelector('input[name="' + name + '"]:checked');
    return input ? input.value : null;
  }

  function each(selector, fn, root) {
    Array.prototype.forEach.call((root || document).querySelectorAll(selector), fn);
  }

  function onReady() {
    // Sheets (the + menu, pot details) close on their ✕, a tap outside, or a
    // drag down from the top. Their links still work without JS. (The page
    // behind can't scroll: only .scroller does, and the sheet covers it.)
    // Opening one focuses its title, not its first button: the iPhone
    // home-screen app drew a focus ring round the ✕ after a tap.
    each('dialog.sheet', function (sheet) {
      if (!sheet.showModal) return;
      var dragged = sheetDrag(sheet);
      sheet.addEventListener('click', function (event) {
        if (event.target === sheet && !dragged()) sheet.close();
      });
    });
    each('[data-sheet]', function (link) {
      var sheet = document.getElementById(link.dataset.sheet);
      if (!sheet || !sheet.showModal) return;
      link.addEventListener('click', function (event) {
        event.preventDefault();
        sheet.showModal();
        var title = sheet.querySelector('h2[tabindex]');
        if (title) title.focus();
      });
    });

    each('[data-fill]', function (button) {
      button.addEventListener('click', function () {
        var input = document.getElementById(button.dataset.fill);
        input.value = button.dataset.value;
        input.dispatchEvent(new Event('input'));
      });
    });

    // Copies a read-only field (the SMS inbox link) to the clipboard.
    each('[data-copy]', function (button) {
      button.addEventListener('click', function () {
        var input = document.getElementById(button.dataset.copy);
        var done = function () { button.lastChild.textContent = 'Copied'; };
        input.select();
        if (navigator.clipboard) navigator.clipboard.writeText(input.value).then(done, function () { document.execCommand('copy'); done(); });
        else { document.execCommand('copy'); done(); }
      });
    });

    each('form[data-confirm]', function (form) {
      form.addEventListener('submit', function (event) {
        if (!window.confirm(form.dataset.confirm)) event.preventDefault();
      });
    });

    each('form[data-autosubmit] select', function (select) {
      select.addEventListener('change', function () { select.form.submit(); });
    });

    // Big amount inputs grow with what's typed, keeping "GH₵" beside the number.
    each('.amount input', function (input) {
      function fit() { input.style.width = (Math.max(input.value.length, 4) + 0.5) + 'ch'; }
      input.addEventListener('input', fit);
      fit();
    });

    each('[data-bill-for]', billField);
    each('[data-show-when]', showWhen);
    each('[data-compact-for]', compactBar);
    each('form[data-split]', splitPreview);
    each('form[data-hints]', balanceHints);
    each('form[data-check]', checkPreview);
    each('form[data-cover]', coverField);
    each('form[data-invest]', tenorButtons);
    each('form[data-percent-total]', percentTotal);
  }

  // Lets a sheet be pulled down by its handle or header: past a third of its
  // height, or with a quick flick, it closes; otherwise it springs back.
  // Returns a function telling whether the last press was a drag, so the
  // click that ends a drag isn't taken as a tap outside.
  function sheetDrag(sheet) {
    var startY = null, lastY = 0, lastTime = 0, speed = 0, moved = false;

    function begin(event) {
      if (!event.target.closest('.sheet-handle, .sheet-drag')) return;
      if (event.target.closest('button, a, input, select, textarea')) return;
      startY = lastY = event.clientY;
      lastTime = event.timeStamp;
      speed = 0;
      moved = false;
      sheet.style.transition = 'none';
      sheet.setPointerCapture(event.pointerId);
    }

    function move(event) {
      if (startY === null) return;
      var distance = Math.max(0, event.clientY - startY);
      if (distance > 4) moved = true;
      speed = (event.clientY - lastY) / Math.max(1, event.timeStamp - lastTime);
      lastY = event.clientY;
      lastTime = event.timeStamp;
      sheet.style.transform = 'translateY(' + distance + 'px)';
    }

    function end(event) {
      if (startY === null) return;
      var distance = Math.max(0, event.clientY - startY);
      startY = null;
      sheet.style.transition = 'transform .2s ease';
      if (distance > sheet.offsetHeight / 3 || (distance > 20 && speed > 0.5)) {
        sheet.style.transform = 'translateY(100%)';
        setTimeout(function () {
          sheet.close();
          sheet.style.transition = '';
          sheet.style.transform = '';
        }, 200);
      } else {
        sheet.style.transform = '';
      }
    }

    sheet.addEventListener('pointerdown', begin);
    sheet.addEventListener('pointermove', move);
    sheet.addEventListener('pointerup', end);
    sheet.addEventListener('pointercancel', end);
    return function () {
      var was = moved;
      moved = false;
      return was;
    };
  }

  // "Is it a bill?" only applies to Living: shown (and sent) while Living is
  // the chosen pot.
  function billField(field) {
    var form = field.closest('form');
    var select = field.querySelector('select');

    function render() {
      var living = checked(form, 'pot_id') === field.dataset.billFor;
      field.classList.toggle('hide', !living);
      select.disabled = !living;
    }

    form.addEventListener('change', function (event) {
      if (event.target.name === 'pot_id') render();
    });
    render();
  }

  // The slim bar at the top of home: shown once the green card has scrolled
  // up under it, and tapping it goes back to the top.
  function compactBar(top) {
    var card = document.getElementById(top.dataset.compactFor);
    var scroller = top.closest('.scroller');
    var bar = top.querySelector('.compact');
    if (!card || !scroller || !('IntersectionObserver' in window)) return;

    var covered = top.offsetHeight + bar.offsetHeight;
    new IntersectionObserver(function (entries) {
      var entry = entries[0];
      top.classList.toggle('compact-on', !entry.isIntersecting && entry.boundingClientRect.top < covered);
    }, { root: scroller, rootMargin: '-' + covered + 'px 0px 0px 0px' }).observe(card);
    bar.addEventListener('click', function () {
      scroller.scrollTo({ top: 0, behavior: 'smooth' });
    });
  }

  // Shows a field only while a radio choice has one of its values
  // (data-show-when="repeats=termly,yearly,once"); hidden inputs aren't sent.
  function showWhen(node) {
    var form = node.closest('form');
    var rule = node.dataset.showWhen.split('=');
    var values = rule[1].split(',');

    function render() {
      var shown = values.indexOf(checked(form, rule[0])) >= 0;
      node.classList.toggle('hide', !shown);
      each('input, select, textarea', function (input) { input.disabled = !shown; }, node);
    }

    form.addEventListener('change', function (event) {
      if (event.target.name === rule[0]) render();
    });
    render();
  }

    // Shows how the amount being entered will be shared, like Plan#split.
  function splitPreview(form) {
    var split = data('split-data');
    var amountInput = form.querySelector('[data-amount]');
    var overflowNote = form.parentNode.querySelector('[data-overflow]');

    function modeChanged() {
      var mode = checked(form, 'mode');
      each('[data-show-mode]', function (node) {
        node.classList.toggle('hide', node.dataset.showMode !== mode);
      }, form);
      if (overflowNote && mode !== 'split') overflowNote.classList.add('hide');
      render();
    }

    function render() {
      var amount = parse(amountInput.value) || 0;
      var parts = {};
      var given = 0;
      var future, living;
      split.pots.forEach(function (pot) {
        parts[pot.id] = Math.floor(amount * pot.percent / 100);
        given += parts[pot.id];
        if (pot.kind === 'future') future = pot;
        if (pot.kind === 'living') living = pot;
      });
      parts[future.id] += amount - given;
      var overflow = 0;
      if (split.room !== null && parts[living.id] > split.room) {
        overflow = parts[living.id] - split.room;
        parts[living.id] = split.room;
        parts[future.id] += overflow;
      }
      split.pots.forEach(function (pot) {
        var cell = form.querySelector('[data-part="' + pot.id + '"]');
        if (cell) cell.textContent = amount ? cedis(parts[pot.id]) : '–';
      });
      if (overflowNote) {
        var show = overflow > 0 && checked(form, 'mode') === 'split';
        overflowNote.classList.toggle('hide', !show);
        overflowNote.textContent = show ? living.name + "'s monthly target is covered, so " + cedis(overflow) + ' of its share goes to ' + future.name + '.' : '';
      }
    }

    amountInput.addEventListener('input', render);
    each('[data-mode]', function (input) { input.addEventListener('change', modeChanged); }, form);
    render();
  }

  // Pot balances in the chosen account, next to amounts being moved.
  function balanceHints(form) {
    var balances = data('balances');
    var names = data('pot-names');
    var totals = data('totals');
    var field = form.dataset.hints;

    function render() {
      var accountId = checked(form, field);
      var held = (accountId && balances[accountId]) || {};
      var accountInput = form.querySelector('input[name="' + field + '"]:checked');
      var accountName = accountInput ? accountInput.parentNode.textContent.trim() : '';
      each('[data-hint-pot]', function (node) {
        var value = held[node.dataset.hintPot] || 0;
        node.textContent = node.hasAttribute('data-plain') ? cedis(value) : (accountId ? cedis(value) + ' in ' + accountName : '');
      }, form);
      each('[data-hint-from]', function (node) {
        var potId = checked(form, node.dataset.hintFrom);
        node.textContent = potId && accountId ? names[potId] + ' has ' + cedis(held[potId] || 0) + ' in ' + accountName + '.' : '';
      }, form);
      var total = form.querySelector('[data-app-total]');
      if (total && totals) total.textContent = cedis(totals[accountId] || 0);
      form.dispatchEvent(new Event('hints'));
    }

    form.addEventListener('change', render);
    render();
  }

  // The gap between the real balance and the app's, and what saving does.
  function checkPreview(form) {
    var totals = data('totals');
    var actual = form.querySelector('[name="actual"]');
    var output = form.querySelector('[data-diff]');
    var surplus = form.querySelector('[data-surplus]');

    function render() {
      var value = parse(actual.value);
      var accountId = checked(form, 'account_id');
      var app = totals[accountId] || 0;
      var gap = value === null ? null : value - app;
      if (gap === null) output.textContent = '';
      else if (gap === 0) output.textContent = 'Matches the app. All square.';
      else if (gap < 0) output.textContent = cedis(-gap) + ' less than the app says. Saving records it as spending.';
      else output.textContent = cedis(gap) + ' more than the app says.';
      output.className = 'center small ' + (gap > 0 ? 'pos' : gap < 0 ? 'neg' : '');
      surplus.classList.toggle('hide', !(gap > 0));
    }

    actual.addEventListener('input', render);
    form.addEventListener('change', render);
    render();
  }

  // On a purchase, asks which pot covers what the Buy List pot can't.
  function coverField(form) {
    var balance = parseInt(form.dataset.cover, 10);
    var paid = form.querySelector('[name="paid"]');
    var field = form.querySelector('[data-cover-field]');
    var hint = form.querySelector('[data-cover-hint]');

    function render() {
      var value = parse(paid.value) || 0;
      var short = value - balance;
      field.classList.toggle('hide', short <= 0);
      hint.textContent = short > 0 ? cedis(short) + ' more than the Buy List pot has.' : '';
    }

    paid.addEventListener('input', render);
    render();
  }

  // 91/182/364-day buttons set the maturity date from the start date.
  function tenorButtons(form) {
    var start = form.querySelector('[name="started_on"]');
    var end = form.querySelector('[name="matures_on"]');
    var kind = form.querySelector('[name="kind"]');
    var tenors = form.querySelector('[data-tenors]');

    function showTenors() {
      tenors.classList.toggle('hide', ['tbill', 'deposit'].indexOf(kind.value) < 0);
    }

    each('[data-tenor]', function (button) {
      button.addEventListener('click', function () {
        var date = new Date((start.value || new Date().toISOString().slice(0, 10)) + 'T00:00:00Z');
        date.setUTCDate(date.getUTCDate() + parseInt(button.dataset.tenor, 10));
        end.value = date.toISOString().slice(0, 10);
      });
    }, form);
    kind.addEventListener('change', showTenors);
    showTenors();
  }

  function percentTotal(form) {
    var output = form.querySelector('[data-percent-sum]');

    function render() {
      var total = 0;
      each('[data-percent]', function (input) { total += parseInt(input.value || '0', 10) || 0; }, form);
      output.textContent = 'Total: ' + total + '%' + (total === 100 ? '' : ' (needs to be 100%)');
      output.className = 'small ' + (total === 100 ? 'pos' : 'neg');
    }

    form.addEventListener('input', render);
    render();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', onReady);
  else onReady();

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () { navigator.serviceWorker.register('/sw.js'); });
  }
})();
