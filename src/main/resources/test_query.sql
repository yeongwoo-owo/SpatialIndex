SELECT place_id,
       company_name,
       branch_name,
       address,
       latitude,
       longitude,
       ST_DISTANCE_SPHERE(@user_position, point(longitude, latitude)) as distance
FROM place
WHERE company_name like CONCAT(@name, '%')
ORDER BY distance
LIMIT 10;