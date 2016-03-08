@noinline function sinthesin(x)
    sin(sin(x))
end

function inaloop(y)
    for i = 1:y
	sinthesin(i)
    end
end
