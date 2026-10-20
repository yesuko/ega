// Money Plan: small enhancements on top of plain forms. Every page works
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
    // The add sheet opens from the + tab; the link still works without JS.
    each('[data-sheet]', function (link) {
      var sheet = document.getElementById(link.dataset.sheet);
      if (!sheet || !sheet.showModal) return;
      link.addEventListener('click', function (event) {
        event.preventDefault();
        sheet.showModal();
      });
      sheet.addEventListener('click', function (event) {
        if (event.target === sheet) sheet.close();
      });
    });

    each('[data-fill]', function (button) {
      button.addEventListener('click', function () {
        var input = document.getElementById(button.dataset.fill);
        input.value = button.dataset.value;
        input.dispatchEvent(new Event('input'));
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

    each('form[data-split]', splitPreview);
    each('form[data-hints]', balanceHints);
    each('form[data-check]', checkPreview);
    each('form[data-cover]', coverField);
    each('form[data-invest]', tenorButtons);
    each('form[data-percent-total]', percentTotal);
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
