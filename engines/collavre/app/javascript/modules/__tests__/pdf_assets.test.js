import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { runInNewContext } from 'node:vm'
import { jest } from '@jest/globals'

test('gem PDF entry points coexist with generic host PDF assets', () => {
  const gemPath = path.resolve('engines/collavre')
  const hostEntries = ['app/javascript/pdf_viewer.js', 'app/javascript/pdf_worker.js']
  const gemEntries = readdirSync(`${gemPath}/app/javascript`)
    .filter(name => name.endsWith('.js')).map(name => `${gemPath}/app/javascript/${name}`)
  const build = jest.fn().mockResolvedValue({})
  const dependencies = {
    esbuild: { build }, glob: { sync: pattern => pattern.startsWith(gemPath) ? gemEntries :
      (pattern.startsWith('app/') ? hostEntries : []) },
    path, child_process: {}, fs: { existsSync: () => false }
  }
  runInNewContext(readFileSync('engines/collavre/lib/generators/collavre/install/templates/build.cjs.tt', 'utf8'), {
    require: name => dependencies[name], console,
    process: { env: { COLLAVRE_GEM_PATH: gemPath }, cwd: () => '/host', argv: [], exit: jest.fn() }
  })
  const entries = build.mock.calls[0][0].entryPoints
  expect(entries.pdf_viewer).toBe(hostEntries[0])
  expect(entries.pdf_worker).toBe(hostEntries[1])
  expect(entries.collavre_pdf_viewer).toBe(`${gemPath}/app/javascript/collavre_pdf_viewer.js`)
  expect(entries.collavre_pdf_worker).toBe(`${gemPath}/app/javascript/collavre_pdf_worker.js`)
})
