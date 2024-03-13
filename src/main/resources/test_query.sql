SELECT place_id,
       company_name,
       branch_name,
       address,
       latitude,
       longitude,
       ST_DISTANCE_SPHERE(@user_position, point(longitude, latitude)) as distance
FROM place
WHERE match(company_name) against(@name)
ORDER BY distance
LIMIT 10;