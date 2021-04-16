import componentTest, {
  setupRenderingTest,
} from "discourse/tests/helpers/component-test";
import {
  discourseModule,
  exists,
  query,
} from "discourse/tests/helpers/qunit-helpers";
import hbs from "htmlbars-inline-precompile";
import selectKit from "discourse/tests/helpers/select-kit-helper";
import I18n from "I18n";

function assertOptionExists(assert, name, num) {
  assert.ok(
    query(`ul.select-kit-collection li:nth-child(${num}) span`).innerText ===
      name,
    `"${name}" is rendered`
  );
}

discourseModule(
  "Integration | Component | select-kit/future-date-input-selector",
  function (hooks) {
    setupRenderingTest(hooks);

    hooks.beforeEach(function () {
      this.set("subject", selectKit());
    });

    componentTest("rendering and expanding", {
      template: hbs`
        {{future-date-input-selector
          options=(hash
            none="topic.auto_update_input.none"
          )
        }}
      `,

      async test(assert) {
        assert.ok(
          exists("div.future-date-input-selector"),
          "Selector is rendered"
        );

        assert.ok(
          query("span").innerText === I18n.t("topic.auto_update_input.none"),
          "Default text is rendered"
        );

        await this.subject.expand();

        assert.ok(exists("div.select-kit-body"), "Selector is expanded");

        assert.ok(
          exists("ul.select-kit-collection"),
          "List of options is rendered"
        );
      },
    });

    componentTest("default options", {
      template: hbs`{{future-date-input-selector}}`,

      async test(assert) {
        await this.subject.expand();

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.tomorrow"),
          1
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.next_week"),
          2
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.two_weeks"),
          3
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.next_month"),
          4
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.two_months"),
          5
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.three_months"),
          6
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.four_months"),
          7
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.six_months"),
          8
        );

        assert.notOk(
          query(`ul.select-kit-collection li:nth-child(9) span`),
          "9th option doesn't exist"
        );
      },
    });

    componentTest("far feature options", {
      template: hbs`
        {{future-date-input-selector
          includeFarFuture=true
        }}
      `,

      async test(assert) {
        await this.subject.expand();

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.one_year"),
          9
        );

        assertOptionExists(
          assert,
          I18n.t("topic.auto_update_input.forever"),
          10
        );

        assert.notOk(
          query(`ul.select-kit-collection li:nth-child(11) span`),
          "11th option doesn't exist"
        );
      },
    });
  }
);
