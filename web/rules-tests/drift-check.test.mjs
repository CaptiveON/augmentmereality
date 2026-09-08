import assert from 'node:assert/strict';
import test from 'node:test';
import { appReactionFields, parseAppReactionFields } from './drift-check.mjs';

test('reaction fixture types match the current synthesized Codable fields', () => {
  assert.deepEqual(appReactionFields(), [
    { name: 'id', type: 'String' },
    { name: 'emoji', type: 'String' },
    { name: 'uid', type: 'String' },
    { name: 'byName', type: 'String' },
    { name: 'at', type: 'Date' },
  ]);
});

const declaration = (body) => `struct DropReaction: Codable {\n${body}\n}`;
const fields = '    var id: String\n    let emoji: String\n    var uid: String';

for (const customization of [
  '    enum CodingKeys: String, CodingKey { case uid = "author" }',
  '    func encode(to encoder: Encoder) throws {}',
  '    @DocumentID var documentID: String?',
  '    var byName: String { "Computed" }',
  '    private var extraEncodedField: String',
]) {
  test(`reaction drift parser fails closed for ${customization.trim()}`, () => {
    assert.throws(() => parseAppReactionFields(declaration(`${fields}\n${customization}`)));
  });
}

test('reaction drift parser rejects an empty shape instead of passing vacuously', () => {
  assert.throws(() => parseAppReactionFields(declaration('')));
});

test('reaction extensions require review instead of hiding custom encoding from the lock', () => {
  assert.throws(() => parseAppReactionFields(`${declaration(fields)}\nextension DropReaction {\n}`));
});
