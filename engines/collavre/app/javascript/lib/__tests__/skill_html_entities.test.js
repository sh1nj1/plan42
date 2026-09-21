import { decodeHtmlEntities } from "../../../../skills/collavre/scripts/html_entities.js";

describe("decodeHtmlEntities", () => {
  test("decodes supported named and numeric entities", () => {
    expect(decodeHtmlEntities("A &amp; B &lt;x&gt; &quot;q&quot; &#39;a&#39;&nbsp;&#65;&#x42;"))
      .toBe("A & B <x> \"q\" 'a' AB");
  });

  test("decodes each entity exactly once", () => {
    expect(decodeHtmlEntities("&amp;lt; &amp;#60; &#38;gt; &#x26;quot;"))
      .toBe("&lt; &#60; &gt; &quot;");
  });

  test("preserves unsupported and out-of-range entities", () => {
    expect(decodeHtmlEntities("&copy; &#x110000;"))
      .toBe("&copy; &#x110000;");
  });

  test("preserves empty values", () => {
    expect(decodeHtmlEntities("")).toBe("");
    expect(decodeHtmlEntities(null)).toBeNull();
  });
});
