# LiveStore Schema Design for Plan42 Creatives

## Events 설계

### Creative 이벤트
```typescript
// schema/creative-events.ts
import { Events, Schema } from '@livestore/livestore';

export const creativeEvents = {
  // 생성
  creativeCreated: Events.synced({
    name: 'v1.CreativeCreated',
    schema: Schema.Struct({
      id: Schema.String,
      userId: Schema.String,
      parentId: Schema.String.pipe(Schema.optional),
      description: Schema.String.pipe(Schema.optional),
      sequence: Schema.Number.pipe(Schema.optional),
      progress: Schema.Number.pipe(Schema.optional),
    }),
  }),

  // 수정
  creativeUpdated: Events.synced({
    name: 'v1.CreativeUpdated',
    schema: Schema.Struct({
      id: Schema.String,
      description: Schema.String.pipe(Schema.optional),
      progress: Schema.Number.pipe(Schema.optional),
    }),
  }),

  // 이동/재정렬
  creativeMoved: Events.synced({
    name: 'v1.CreativeMoved',
    schema: Schema.Struct({
      id: Schema.String,
      newParentId: Schema.String.pipe(Schema.optional),
      newSequence: Schema.Number,
    }),
  }),

  // 다중 이동
  creativesBulkMoved: Events.synced({
    name: 'v1.CreativesBulkMoved',
    schema: Schema.Struct({
      ids: Schema.Array(Schema.String),
      targetId: Schema.String,
      direction: Schema.Literal(['up', 'down', 'child']),
    }),
  }),

  // 링크드 크리에이티브 생성
  linkedCreativeCreated: Events.synced({
    name: 'v1.LinkedCreativeCreated',
    schema: Schema.Struct({
      id: Schema.String,
      originId: Schema.String,
      parentId: Schema.String.pipe(Schema.optional),
      userId: Schema.String,
      sequence: Schema.Number,
    }),
  }),

  // 삭제
  creativeDeleted: Events.synced({
    name: 'v1.CreativeDeleted',
    schema: Schema.Struct({
      id: Schema.String,
      deletedAt: Schema.DateFromNumber,
    }),
  }),

  // 공유
  creativeShared: Events.synced({
    name: 'v1.CreativeShared',
    schema: Schema.Struct({
      creativeId: Schema.String,
      userId: Schema.String,
      sharedWithUserId: Schema.String,
      permission: Schema.Literal(['read', 'write', 'admin']),
    }),
  }),

  // 확장 상태
  creativeExpandedStateChanged: Events.synced({
    name: 'v1.CreativeExpandedStateChanged',
    schema: Schema.Struct({
      userId: Schema.String,
      creativeId: Schema.String,
      expanded: Schema.Boolean,
    }),
  }),
};
```

## State 테이블 설계

```typescript
// schema/creative-tables.ts
import { State, Schema } from '@livestore/livestore';

export const tables = {
  // 메인 크리에이티브 테이블
  creatives: State.SQLite.table({
    name: 'creatives',
    columns: {
      id: State.SQLite.text({ primaryKey: true }),
      userId: State.SQLite.text({ indexed: true }),
      parentId: State.SQLite.text({ nullable: true, indexed: true }),
      originId: State.SQLite.text({ nullable: true, indexed: true }),
      description: State.SQLite.text({ default: '' }),
      progress: State.SQLite.real({ default: 0.0 }),
      sequence: State.SQLite.integer({ default: 0 }),
      createdAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
      updatedAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
      deletedAt: State.SQLite.integer({ nullable: true, schema: Schema.DateFromNumber }),
    },
  }),

  // 공유 테이블
  creativeShares: State.SQLite.table({
    name: 'creative_shares',
    columns: {
      id: State.SQLite.text({ primaryKey: true }),
      creativeId: State.SQLite.text({ indexed: true }),
      userId: State.SQLite.text({ indexed: true }),
      sharedWithUserId: State.SQLite.text({ indexed: true }),
      permission: State.SQLite.text({ default: 'read' }),
      createdAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
    },
  }),

  // 확장 상태 테이블
  creativeExpandedStates: State.SQLite.table({
    name: 'creative_expanded_states',
    columns: {
      id: State.SQLite.text({ primaryKey: true }),
      userId: State.SQLite.text({ indexed: true }),
      creativeId: State.SQLite.text({ indexed: true }),
      expanded: State.SQLite.boolean({ default: false }),
      updatedAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
    },
  }),

  // 댓글 테이블
  comments: State.SQLite.table({
    name: 'comments',
    columns: {
      id: State.SQLite.text({ primaryKey: true }),
      creativeId: State.SQLite.text({ indexed: true }),
      userId: State.SQLite.text({ indexed: true }),
      content: State.SQLite.text(),
      createdAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
      updatedAt: State.SQLite.integer({ schema: Schema.DateFromNumber }),
      deletedAt: State.SQLite.integer({ nullable: true, schema: Schema.DateFromNumber }),
    },
  }),
};
```

## Materializers 설계

```typescript
// schema/creative-materializers.ts
import { State } from '@livestore/livestore';
import { creativeEvents } from './creative-events';
import { tables } from './creative-tables';

export const materializers = State.SQLite.materializers(creativeEvents, {
  'v1.CreativeCreated': ({ id, userId, parentId, description, sequence, progress }) => 
    tables.creatives.insert({
      id,
      userId,
      parentId: parentId || null,
      description: description || '',
      sequence: sequence || 0,
      progress: progress || 0.0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),

  'v1.CreativeUpdated': ({ id, description, progress }) => 
    tables.creatives.update({
      ...(description !== undefined && { description }),
      ...(progress !== undefined && { progress }),
      updatedAt: Date.now(),
    }).where({ id }),

  'v1.CreativeMoved': ({ id, newParentId, newSequence }) => 
    tables.creatives.update({
      parentId: newParentId || null,
      sequence: newSequence,
      updatedAt: Date.now(),
    }).where({ id }),

  'v1.CreativesBulkMoved': ({ ids, targetId, direction }) => {
    // 복잡한 bulk move 로직은 여러 SQL 쿼리로 구현
    // 1. 타겟의 현재 sequence와 parentId 가져오기
    // 2. ids의 새로운 sequence 계산
    // 3. 업데이트 실행
  },

  'v1.LinkedCreativeCreated': ({ id, originId, parentId, userId, sequence }) => 
    tables.creatives.insert({
      id,
      originId,
      parentId: parentId || null,
      userId,
      sequence,
      progress: 0.0,
      description: '', // 링크드는 origin의 description 참조
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }),

  'v1.CreativeDeleted': ({ id, deletedAt }) => 
    tables.creatives.update({
      deletedAt,
      updatedAt: Date.now(),
    }).where({ id }),

  'v1.CreativeShared': ({ creativeId, userId, sharedWithUserId, permission }) => 
    tables.creativeShares.insert({
      id: `${creativeId}-${sharedWithUserId}`,
      creativeId,
      userId,
      sharedWithUserId,
      permission,
      createdAt: Date.now(),
    }),

  'v1.CreativeExpandedStateChanged': ({ userId, creativeId, expanded }) => 
    tables.creativeExpandedStates.insertOrReplace({
      id: `${userId}-${creativeId}`,
      userId,
      creativeId,
      expanded,
      updatedAt: Date.now(),
    }),
});
```

## 반응형 쿼리 설계

```typescript
// queries/creative-queries.ts
import { queryDb } from '@livestore/livestore';
import { tables } from '../schema/creative-tables';

// 사용자의 루트 크리에이티브들
export const userRootCreatives$ = (userId: string) => 
  queryDb(() => 
    tables.creatives
      .where({ userId, parentId: null, deletedAt: null })
      .orderBy('sequence')
  );

// 특정 부모의 자식들
export const childCreatives$ = (parentId: string) => 
  queryDb(() => 
    tables.creatives
      .where({ parentId, deletedAt: null })
      .orderBy('sequence')
  );

// 크리에이티브 트리 (재귀적)
export const creativeTree$ = (userId: string, parentId?: string) => 
  queryDb(() => {
    // SQLite CTE를 사용한 재귀 쿼리
    return `
      WITH RECURSIVE creative_tree AS (
        SELECT *, 0 as level 
        FROM creatives 
        WHERE user_id = ? AND parent_id ${parentId ? '= ?' : 'IS NULL'} AND deleted_at IS NULL
        
        UNION ALL
        
        SELECT c.*, ct.level + 1
        FROM creatives c
        INNER JOIN creative_tree ct ON c.parent_id = ct.id
        WHERE c.deleted_at IS NULL
      )
      SELECT * FROM creative_tree ORDER BY level, sequence
    `;
  });

// 공유된 크리에이티브들
export const sharedCreatives$ = (userId: string) => 
  queryDb(() => 
    tables.creatives
      .innerJoin(tables.creativeShares, 'creatives.id = creative_shares.creative_id')
      .where('creative_shares.shared_with_user_id = ? AND creatives.deleted_at IS NULL', userId)
      .select('creatives.*', 'creative_shares.permission')
  );

// 확장 상태 맵
export const expandedStateMap$ = (userId: string) => 
  queryDb(() => 
    tables.creativeExpandedStates
      .where({ userId })
      .select('creative_id as creativeId', 'expanded')
  );
```
