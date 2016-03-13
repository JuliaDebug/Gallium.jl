@noinline function sinthesin(x)
    sin(sin(x))
end

@noinline function inaloop(y)
    for i = 1:y
	sinthesin(i)
    end
end
