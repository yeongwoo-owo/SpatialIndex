# 장소 검색 쿼리 개선
## 문제 상황
우주라이크 앱을 개발하며 다음과 같은 요구사항이 있었다.
> 사용자가 장소를 검색하면 검색어를 포함한 장소를 가까운 순서대로 조회한다.

공공 데이터의 상권 정보를 이용해서 총 250만 개의 장소 정보를 획득하고, 하버시안 공식을 이용하여 계산한 거리로 장소를 정렬하는 SQL을 작성했다.
```sql
SELECT place_id AS placeId,
       name,
       code,
       address,
       road_address AS roadAddress,
       latitude,
       longitude,
       (6371 * acos(cos(radians(:latitude)) * cos(radians(:longitude)) + sin(radians(:latitude)) * sin(radians(latitude)))) AS distance
FROM place
WHERE name LIKE :name
ORDER BY distance
```

하지만 해당 쿼리는 두 가지 문제점이 있었다.
1. EC2 프리티어 개발 환경에서 응답까지 10초 이상의 시간이 소요되는 문제
2. 파일 데이터를 이용하여 주기적으로 데이터를 갱신해야 하는 문제

이러한 문제로 인해 외부 API를 활용하는 것이 더 효율적이라고 생각했고, 카카오 로컬 API를 이용하는 방법으로 계획을 변경했다.<br>
해당 쿼리를 직접 개선하지 못한 것에 대한 아쉬움이 남았고, 직접 쿼리를 개선해보기로 했다.

## 쿼리 개선
### 테스트 환경
테스트 데이터는 프로젝트와 동일하게 상권 정보를 다운로드받아 MySQL에 저장해두었다.
테스트에 사용될 변수는 다음과 같이 설정했고, 검색어 조회에 이용할 인덱스를 생성했다.
```sql
SET @latitude = 37.47268564757623;
SET @longitude = 127.15240622792602;
SET @user_position = point(@longitude, @latitude);
SET @name = '강정';

CREATE INDEX name_like_index ON place (company_name);
```

테스트에서 사용할 쿼리는 MySQL의 ST_DISTANCE_SPHERE() 함수를 이용하는 방법이다.
```sql
SELECT place_id,
       company_name,
       branch_name,
       address,
       latitude,
       longitude,
       ST_DISTANCE_SPHERE(@user_position, point(longitude, latitude)) as distance
FROM place
WHERE company_name like CONCAT('%', @name, '%')
ORDER BY distance
LIMIT 10;
```
해당 쿼리를 EXPLAIN 문을 통해 실행하면 쿼리 계획이 ALL으로, 모든 row를 조회하는 방법을 이용한다는 것을 알 수 있다. 효율적인 데이터 조회를 위해서는 인덱스를 활용해야 한다.

| 시도  | 실행 시간(ms) |
|-----|-----------|
| 1   | 988       |
| 2   | 932       |
| 3   | 981       |
| 4   | 977       |
| 5   | 938       |
| 평균  | 963.2     |

해당 쿼리를 총 5번 실행한 결과 평균 963.2ms가 측정되었다.

### 공간 인덱스 적용
공간 인덱스란 좌표 정보를 나타내는 Point 타입의 인덱스로, 위치 관련 쿼리를 최적화하는데 사용된다.
위도와 경도 정보를 합한 Point 타입의 컬럼인 coordinate를 생성하고, 해당 컬럼을 이용해서 인덱스를 만들었다.
```sql
ALTER TABLE place ADD COLUMN coordinate POINT;
UPDATE place set coordinate=Point(longitude, latitude);
ALTER TABLE place MODIFY coordinate POINT NOT NULL;
CREATE SPATIAL INDEX coordinate_index ON place (coordinate);
```

해당 쿼리를 실행하면 다음과 같은 오류 메세지를 출력한다.
> The spatial index on column 'coordinate' will not be used by the query optimizer since the column does not have an SRID attribute. Consider adding an SRID attribute to the column.
> -> coordinate의 공간 인덱스는 SRID 속성이 없기 때문에 Query Optimizer에 의해 최적화되지 않습니다.  컬럼에 SRID 속성을 추가하세요.

SRID란 공간 좌표계에 관한 정보를 나타내는 겂으로, MySQL 5.7 버전까지는 여러 SRID를 이용해서 공간 인덱스를 사용할 수 있었기 때문에 별도의 설정이 필요 없었지만, MySQL 8.0부터는 하나의 SRID로 설정하지 않는 경우 인덱스를 무시한다.

따라서 테이블을 다음과 같이 수정했고, coordinate 컬럼과 coordinate_index 인덱스를 생성했다.
```sql
ALTER TABLE place  ADD COLUMN coordinate POINT SRID 4326;
UPDATE place SET coordinate=ST_PointFromText(CONCAT('POINT(', latitude, longitude, ')'), 4326);
ALTER TABLE place MODIFY coordinate POINT NOT NULL SRID 4326;
CREATE SPATIAL INDEX coordinate_index ON place (coordinate);
```

하지만 쿼리는 개선되지 않았고, 여전히 쿼리 타입은 ALL이었다.
### FullText 인덱스 적용
쿼리가 여전히 인덱스를 사용하지 않는 이유는 장소 이름 인덱스의 타입이 VarChar이기 때문이다.
MySQL의 인덱스는 B-Tree 자료구조를 이용하며, 정렬된 상태를 유지한다. VarChar 타입의 경우 문자열을 정렬된 상태로 유지하기 때문에 특정 문자열로 시작하는 결과를 찾는 경우 찾아야 하는 범위를 제한할 수 있기 때문에 성능 개선이 일어난다. 하지만 위의 쿼리는 문자열 중간의 단어로 검색하는 경우에도 검색이 되야 하기 때문에 범위를 제한할 수 없고, 모든 컬럼을 찾아 조회할 수 밖에 없다.

VarChar 타입의 인덱스를 FullText 인덱스로 변경하면 해당 문제를 해결할 수 있다. FullText란 Char, VarChar, Text 컬럼의 문자열을 토큰화하여 인덱스를 만들어내는 방식이다. 문자열을 각각 토큰화하여 일치 여부를 판단하기 때문에 중간 단어를 검색하는 경우에도 인덱스를 적용할 수 있다.
```sql
ALTER TABLE place DROP INDEX name_like_index;
CREATE FULLTEXT INDEX name_like_index ON place (company_name) WITH PARSER ngram;
```

FullText를 이용하려면 쿼리도 변경이 필요하다.
```sql
SELECT place_id,
       company_name,
       branch_name,
       address,
       latitude,
       longitude,
       ST_DISTANCE_SPHERE(@user_position, point(longitude, latitude)) AS distance
FROM place
WHERE MATCH(company_name) against(@name IN NATURAL LANGUAGE MODE)
ORDER BY distance
LIMIT 10;
```

FullText를 도입한 결과 인덱스 타입이 RANGE로 변경되는 것을 확인할 수 있다.

| 시도  | 실행 시간(ms) |
|-----|-----------|
| 1   | 113       |
| 2   | 99        |
| 3   | 80        |
| 4   | 98        |
| 5   | 74        |
| 평균  | 92.8      |

쿼리를 5번 실행한 결과 응답 시간이 92.8ms로, 기존의 963.2ms에 비해 10배 이상 조회 성능이 향상되었다.

## 결론
공간 인덱스와 FullText 인덱스를 적절히 활용한 결과 쿼리 조회 성능이 10배 이상 상승한 것을 확인할 수 있었다.
FullText 인덱스를 보다 최적화한다면 쿼리 속도를 더 올릴 수 있을 것 같다.

## 참고
> ### FullText 인덱스 조회 방법
> 1. Natural Language (Default): 별도의 연산 없이 쿼리를 토큰화한 후 일치 여부를 확인
> 2. Bool Search: 검색 단어와 연산자를 이용해서 단어의 연관성을 계산
> 3. Query Expansion: Natural Language 방식의 쿼리를 확장, 쿼리 결과 검색된 데이터에서 높은 우선순위의 토큰을 찾아 해당 토큰을 통해 재검색
> > Bool Search 연산자
> > - +: 반드시 포함해야 하는 단어
> > - -: 반드시 제외해야 하는 단어
> > - \>: 검색 순위를 높일 단어
> > - <: 검색 순위를 낮출 단어
> > - (): 하위 표현식으로 그룹화

> ### FullText Parser
> 1. Default Parser: 구분자를 기준으로 쿼리를 토큰화하는 Parser
> 2. NGram Parser: 쿼리를 지정한 크기(ngram_token_size)로 토큰화하는 Parser
     >    - White Space를 포함하지 않는다.
>    - MySQL에 내장되어 있으며, 중국어, 일본어, 한국어를 지원한다.

## 참조
> - [\[\[MySQL\] ST_DISTANCE_SPHERE 함수를 활용하여 거리/반경 구하기\]](https://jinooh.tistory.com/76)
> - [공간 인덱스로 조회속도 32배 개선하기(요즘 카페 지도 기능 개발)](https://kong-dev.tistory.com/245)
> - [Upgrading Spatial Indexes to MySQL 8.0](https://dev.mysql.com/blog-archive/upgrading-spatial-indexes-to-mysql-8-0/)
> - [MySQL LIKE % 위치에 따른 인덱스 사용 여부](https://k3068.tistory.com/106)
> - [MySQL 공식 문서](https://dev.mysql.com/doc/refman/8.0/en/fulltext-search.html)
> - [Full Text Search를 이용한 DB 성능 개선 일지](https://www.essential2189.dev/db-performance-fts#9b38512b-b34b-45cf-8f78-7df1a235a128)

